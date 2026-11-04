import Foundation
import Combine

public enum ActiveTransport: String, Sendable {
    case wifi = "Wi-Fi"
    case bluetooth = "Bluetooth"
    case none = "Disconnected"
}

public protocol ConnectionManagerDelegate: AnyObject, Sendable {
    func connectionManager(didReceiveEnvelope envelope: MessageEnvelope)
    func connectionManager(didUpdateTransport transport: ActiveTransport)
    func connectionManager(didCompletePairing device: PairedDevice)
}

public final class ConnectionManager: @unchecked Sendable, WiFiTransportDelegate, BluetoothTransportDelegate {
    public static let shared = ConnectionManager()

    public let wifiTransport = WiFiTransport()
    public let bluetoothTransport = BluetoothTransport()
    public let cryptoManager = CryptoManager.shared

    public weak var delegate: ConnectionManagerDelegate?

    public private(set) var activeTransport: ActiveTransport = .none
    public private(set) var currentPairedDevice: PairedDevice?
    public var connectedIp: String? { wifiTransport.remoteHost }

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private var heartbeatTimer: Timer?
    private let queue = DispatchQueue(label: "com.droiddock.connectionmanager", qos: .userInitiated)

    public init() {
        wifiTransport.delegate = self
        bluetoothTransport.delegate = self
        loadPersistedDevice()
    }

    public func startServices() {
        do {
            try wifiTransport.startListening()
        } catch {
            print("[ConnectionManager] Failed to start Wi-Fi listener: \(error)")
        }
        bluetoothTransport.startAdvertising()
        startHeartbeat()
    }

    public func stopServices() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        wifiTransport.stop()
        bluetoothTransport.stop()
        updateTransport()
    }

    private func startHeartbeat() {
        DispatchQueue.main.async {
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        guard currentPairedDevice != nil && activeTransport != .none else { return }
        let envelope = MessageEnvelope(type: .heartbeat, payload: "ping")
        sendEnvelope(envelope)
    }

    private func updateTransport() {
        let newTransport: ActiveTransport
        if wifiTransport.isConnected {
            newTransport = .wifi
        } else if bluetoothTransport.isConnected {
            newTransport = .bluetooth
        } else {
            newTransport = .none
        }

        if newTransport != activeTransport {
            activeTransport = newTransport
            print("[ConnectionManager] Active transport updated to: \(newTransport.rawValue)")
            DispatchQueue.main.async {
                self.delegate?.connectionManager(didUpdateTransport: newTransport)
            }
        }
    }

    // MARK: - Sending Envelopes
    public func sendEnvelope(_ envelope: MessageEnvelope, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let device = currentPairedDevice else {
            completion?(false)
            return
        }

        queue.async {
            do {
                let jsonData = try self.jsonEncoder.encode(envelope)
                let encryptedPacket = try self.cryptoManager.encrypt(deviceId: device.id, plaintext: jsonData)

                // Try Wi-Fi first
                if self.wifiTransport.isConnected {
                    self.wifiTransport.send(data: encryptedPacket) { error in
                        if error == nil {
                            completion?(true)
                        } else {
                            // Wi-Fi send failed, try Bluetooth fallback
                            print("[ConnectionManager] Wi-Fi send failed, attempting Bluetooth fallback")
                            self.bluetoothTransport.send(data: encryptedPacket) { btError in
                                completion?(btError == nil)
                            }
                        }
                    }
                } else if self.bluetoothTransport.isConnected {
                    self.bluetoothTransport.send(data: encryptedPacket) { btError in
                        completion?(btError == nil)
                    }
                } else {
                    completion?(false)
                }
            } catch {
                print("[ConnectionManager] Encryption or encoding error: \(error)")
                completion?(false)
            }
        }
    }

    // MARK: - Inbound Processing
    private func handleInboundData(_ data: Data) {
        queue.async {
            // First check if this is an unencrypted pairing request
            if let envelope = try? self.jsonDecoder.decode(MessageEnvelope.self, from: data),
               envelope.type == .pairingRequest {
                self.processPairingRequest(envelope)
                return
            }

            if self.currentPairedDevice == nil {
                self.loadPersistedDevice()
            }

            let deviceId = self.currentPairedDevice?.id ?? "paired_device"
            do {
                let decrypted = try self.cryptoManager.decrypt(deviceId: deviceId, packet: data)
                let envelope = try self.jsonDecoder.decode(MessageEnvelope.self, from: decrypted)

                DispatchQueue.main.async {
                    self.delegate?.connectionManager(didReceiveEnvelope: envelope)
                }
            } catch {
                print("[ConnectionManager] Inbound decryption/decoding error: \(error)")
            }
        }
    }

    // MARK: - Pairing Handshake
    private func processPairingRequest(_ envelope: MessageEnvelope) {
        guard let payloadData = envelope.payload.data(using: .utf8),
              let req = try? jsonDecoder.decode(PairingPayload.self, from: payloadData) else {
            print("[ConnectionManager] Malformed pairing request payload")
            return
        }

        do {
            try cryptoManager.establishSharedKey(deviceId: req.deviceId, remotePublicKeyBase64: req.publicKey)
            cryptoManager.resetSequenceCounters(for: req.deviceId)

            let paired = PairedDevice(
                id: req.deviceId,
                name: req.deviceName,
                publicKey: req.publicKey,
                lastSeen: Date(),
                transportType: activeTransport.rawValue,
                isTrusted: true
            )
            self.currentPairedDevice = paired
            self.persistDevice(paired)

            // Send Pairing Response back
            let confirmation = PairingConfirmation(
                status: "accepted",
                deviceId: Host.current().localizedName ?? "Mac",
                deviceName: Host.current().localizedName ?? "Mac",
                publicKey: cryptoManager.localPublicKeyBase64,
                nonceResponse: req.pairingNonce
            )
            let confData = try jsonEncoder.encode(confirmation)
            let confJson = String(data: confData, encoding: .utf8) ?? ""
            let respEnvelope = MessageEnvelope(type: .pairingResponse, payload: confJson)

            // Send unencrypted confirmation for initial handshake completion
            let respData = try jsonEncoder.encode(respEnvelope)
            if wifiTransport.isConnected {
                wifiTransport.send(data: respData)
            } else {
                bluetoothTransport.send(data: respData)
            }

            DispatchQueue.main.async {
                self.delegate?.connectionManager(didCompletePairing: paired)
            }
        } catch {
            print("[ConnectionManager] Handshake failed: \(error)")
        }
    }

    // MARK: - Persistence
    private func persistDevice(_ device: PairedDevice) {
        if let data = try? jsonEncoder.encode(device) {
            KeychainStore.save(key: "droiddock_paired_device_meta", data: data)
        }
    }

    private func loadPersistedDevice() {
        if let data = KeychainStore.load(key: "droiddock_paired_device_meta"),
           let device = try? jsonDecoder.decode(PairedDevice.self, from: data) {
            self.currentPairedDevice = device
            _ = cryptoManager.restorePairedDevice(deviceId: device.id)
            print("[ConnectionManager] Restored paired device: \(device.name) (\(device.id))")
        }
    }

    public func unpairDevice() {
        if let device = currentPairedDevice {
            cryptoManager.removePairedDevice(deviceId: device.id)
            KeychainStore.delete(key: "droiddock_paired_device_meta")
            currentPairedDevice = nil
            print("[ConnectionManager] Device unpaired successfully")
        }
    }

    // MARK: - WiFiTransportDelegate
    public func wifiTransportDidReceive(data: Data) {
        handleInboundData(data)
    }

    public func wifiTransportDidChangeState(isConnected: Bool) {
        updateTransport()
        if isConnected {
            cryptoManager.resetSequenceCounters()
        }
    }

    // MARK: - BluetoothTransportDelegate
    public func bluetoothTransportDidReceive(data: Data) {
        handleInboundData(data)
    }

    public func bluetoothTransportDidChangeState(isConnected: Bool) {
        updateTransport()
    }
}
