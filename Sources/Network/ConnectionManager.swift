import Foundation
import Combine

public enum ActiveTransport: String, Sendable, Hashable {
    case wifi = "Wi-Fi"
    case bluetooth = "Bluetooth"
    case none = "Disconnected"
    var channelName: String { self == .wifi ? "wifi" : "bluetooth" }
    static func preferred(wifi: Bool, bluetooth: Bool, fallbackEnabled: Bool = true) -> Self {
        wifi ? .wifi : (bluetooth && fallbackEnabled ? .bluetooth : .none)
    }
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
    public var connectedIp: String? { activeTransport == .wifi ? wifiTransport.remoteHost : nil }
    public var bluetoothFallbackEnabled: Bool { UserDefaults.standard.object(forKey: "bluetoothFallbackEnabled") as? Bool ?? true }

    private let queue = DispatchQueue(label: "com.droiddock.connectionmanager", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var timer: DispatchSourceTimer?
    private var fallbackEnabled = true
    private var lastEndpointAdvertisement = Date.distantPast
    private var rawWiFiConnectedAt: Date?
    private var rawBLEConnectedAt: Date?
    private final class Session: @unchecked Sendable {
        let crypto = CryptoManager()
        let nonce: String
        let created = Date()
        var lastReceived = Date()
        var ready = false
        let notifyPairing: Bool
        init(nonce: String, notifyPairing: Bool) { self.nonce = nonce; self.notifyPairing = notifyPairing }
    }
    private var sessions: [ActiveTransport: Session] = [:]
    private final class Pending: @unchecked Sendable {
        let envelope: MessageEnvelope
        let data: Data
        let completion: (@Sendable (Bool) -> Void)?
        var attempt = UUID()
        var inFlight = false
        var sentAt = Date.distantPast
        var source: ActiveTransport = .none
        init(_ envelope: MessageEnvelope, data: Data, completion: (@Sendable (Bool) -> Void)?) {
            self.envelope = envelope; self.data = data; self.completion = completion
        }
    }
    private var pending: [String: Pending] = [:]
    private var unpairToken = UUID()
    private var pendingBytes = 0
    private var pendingOrder: [String] = []
    private var orderedPending: [Pending] { pendingOrder.compactMap { pending[$0] } }
    private var seen = EnvelopeDeduplicator()

    public init() {
        wifiTransport.delegate = self
        bluetoothTransport.delegate = self
        fallbackEnabled = bluetoothFallbackEnabled
        loadPersistedDevice()
    }

    func verifiedBluetoothReady() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.sessions[.bluetooth]?.ready == true) }
        }
    }

    public func startServices() {
        do { try wifiTransport.startListening() } catch { print("[ConnectionManager] Wi-Fi listener: \(error)") }
        queue.async {
            if self.fallbackEnabled { self.bluetoothTransport.startAdvertising() }
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3, repeating: 3)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stopServices() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.sessions.removeAll()
            self.failPending()
            self.wifiTransport.stop(); self.bluetoothTransport.stop()
            self.updateTransport()
        }
    }

    public func setBluetoothFallbackEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "bluetoothFallbackEnabled")
        queue.async {
            self.fallbackEnabled = enabled
            if enabled { self.bluetoothTransport.startAdvertising() }
            else { self.sessions.removeValue(forKey: .bluetooth); self.bluetoothTransport.stop() }
            self.updateTransport()
        }
    }

    private func tick() {
        let now = Date()
        for source in [ActiveTransport.wifi, .bluetooth] {
            guard let session = sessions[source] else {
                let connectedAt = source == .wifi ? rawWiFiConnectedAt : rawBLEConnectedAt
                if let connectedAt, now.timeIntervalSince(connectedAt) > 20 { disconnect(source) }
                continue
            }
            let activity = source == .bluetooth ? max(session.lastReceived, bluetoothTransport.lastActivity) : session.lastReceived
            if (!session.ready && now.timeIntervalSince(session.created) > 15) || now.timeIntervalSince(activity) > 20 {
                disconnect(source)
                continue
            }
            if session.ready { sendDirect(MessageEnvelope(type: .heartbeat, payload: "ping"), source: source) }
        }
        if sessions[.bluetooth]?.ready == true && now.timeIntervalSince(lastEndpointAdvertisement) > 20 {
            lastEndpointAdvertisement = now
            let endpoints: [String: Any] = ["wifiIps": WiFiTransport.getLocalIPAddresses(), "wifiPort": wifiTransport.port,
                "hostName": Host.current().localizedName.map { $0.replacingOccurrences(of: " ", with: "-") + ".local" } ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: endpoints), let json = String(data: data, encoding: .utf8) {
                sendDirect(MessageEnvelope(type: .transportEndpoints, payload: json), source: .bluetooth)
            }
        }
        updateTransport()
        for item in orderedPending {
            let timeout = item.source == .bluetooth ? max(20, Double(item.data.count) / 500) : 10
            if !item.inFlight && (item.source != activeTransport || now.timeIntervalSince(item.sentAt) > timeout) { transmit(item) }
        }
    }

    private func disconnect(_ source: ActiveTransport) {
        sessions.removeValue(forKey: source)
        if source == .wifi { rawWiFiConnectedAt = nil; wifiTransport.disconnectActiveConnection() }
        else { rawBLEConnectedAt = nil; bluetoothTransport.disconnect() }
    }

    private func updateTransport() {
        let preferred = ActiveTransport.preferred(wifi: sessions[.wifi]?.ready == true && wifiTransport.isConnected,
            bluetooth: sessions[.bluetooth]?.ready == true && bluetoothTransport.isConnected, fallbackEnabled: fallbackEnabled)
        guard preferred != activeTransport else { return }
        activeTransport = preferred
        for item in orderedPending where item.source != preferred {
            item.attempt = UUID() // Late callbacks on the old link cannot modify a new attempt.
            item.inFlight = false
        }
        DispatchQueue.main.async { self.delegate?.connectionManager(didUpdateTransport: preferred) }
        for item in orderedPending where !item.inFlight { transmit(item) }
    }

    public func sendEnvelope(_ envelope: MessageEnvelope, completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async {
            guard self.currentPairedDevice != nil, self.activeTransport != .none,
                  let data = try? self.encoder.encode(envelope), data.count + 36 <= BLEFrameDecoder.maximumFrameSize,
                  self.pending.count < 512, self.pendingBytes + data.count <= 24 * 1024 * 1024 else {
                completion?(false); return
            }
            let item = Pending(envelope, data: data, completion: completion)
            guard self.pending[envelope.id] == nil else { completion?(false); return }
            self.pending[envelope.id] = item; self.pendingBytes += data.count; self.pendingOrder.append(envelope.id)
            self.transmit(item)
        }
    }

    private func transmit(_ item: Pending) {
        guard !item.inFlight, activeTransport != .none, let session = sessions[activeTransport],
              let device = currentPairedDevice else { return }
        let source = activeTransport
        do {
            let packet = try session.crypto.encrypt(deviceId: device.id, plaintext: item.data)
            let attempt = UUID()
            item.attempt = attempt; item.inFlight = true; item.source = source
            sendRaw(packet, source: source) { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, let current = self.pending[item.envelope.id], current === item, item.attempt == attempt else { return }
                    item.inFlight = false; item.sentAt = error == nil ? Date() : .distantPast
                    if error != nil {
                        if self.sessions[source] === session { self.disconnect(source) }
                        self.updateTransport()
                        if self.activeTransport != .none { self.transmit(item) }
                    }
                }
            }
        } catch { print("[ConnectionManager] Could not encrypt: \(error)") }
    }

    private func sendRaw(_ data: Data, source: ActiveTransport, completion: (@Sendable (Error?) -> Void)? = nil) {
        if source == .wifi { wifiTransport.send(data: data, completion: completion) }
        else { bluetoothTransport.send(data: data, completion: completion) }
    }
    private func sendDirect(_ envelope: MessageEnvelope, source: ActiveTransport) {
        guard let session = sessions[source], let device = currentPairedDevice,
              let data = try? encoder.encode(envelope), let packet = try? session.crypto.encrypt(deviceId: device.id, plaintext: data) else { return }
        sendRaw(packet, source: source)
    }

    private func handleInboundData(_ data: Data, source: ActiveTransport) {
        queue.async {
            if let envelope = try? self.decoder.decode(MessageEnvelope.self, from: data), envelope.type == .pairingRequest {
                self.processPairing(envelope, source: source)
                return
            }
            guard let session = self.sessions[source], let device = self.currentPairedDevice else { return }
            do {
                let decrypted = try session.crypto.decrypt(deviceId: device.id, packet: data)
                let envelope = try self.decoder.decode(MessageEnvelope.self, from: decrypted)
                session.lastReceived = Date()
                if !session.ready {
                    session.ready = true
                    self.updateTransport()
                    if session.notifyPairing { DispatchQueue.main.async { self.delegate?.connectionManager(didCompletePairing: device) } }
                }
                if envelope.type == .heartbeat {
                    if envelope.payload != "pong" { self.sendDirect(MessageEnvelope(type: .heartbeat, payload: "pong"), source: source) }
                    return
                }
                if envelope.type == .envelopeAck {
                    if let item = self.pending.removeValue(forKey: envelope.payload) {
                        self.pendingBytes -= item.data.count; self.pendingOrder.removeAll { $0 == envelope.payload }; item.completion?(true)
                    }
                    return
                }
                self.sendDirect(MessageEnvelope(type: .envelopeAck, payload: envelope.id), source: source)
                guard self.seen.insert(envelope.id) else { return }
                if envelope.type == .unpair {
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.clearPairing() }
                } else { DispatchQueue.main.async { self.delegate?.connectionManager(didReceiveEnvelope: envelope) } }
            } catch { print("[ConnectionManager] Rejected \(source.rawValue) packet: \(error)") }
        }
    }

    private func processPairing(_ envelope: MessageEnvelope, source: ActiveTransport) {
        guard let data = envelope.payload.data(using: .utf8), let request = try? decoder.decode(PairingPayload.self, from: data),
              request.version == 2, UUID(uuidString: request.pairingNonce) != nil else { return }
        if let trusted = currentPairedDevice {
            guard trusted.id == request.deviceId, trusted.publicKey == request.publicKey else { disconnect(source); return }
        } else if source == .bluetooth { disconnect(source); return } // Initial QR pairing remains Wi-Fi only.
        do {
            if sessions[source]?.nonce != request.pairingNonce {
                let session = Session(nonce: request.pairingNonce, notifyPairing: currentPairedDevice == nil)
                try session.crypto.establishSharedKey(deviceId: request.deviceId, remotePublicKeyBase64: request.publicKey,
                    salt: "DroidDock_E2EE_v2:\(source.channelName):\(request.pairingNonce)", persistPeer: false)
                sessions[source] = session
            }
            let device = PairedDevice(id: request.deviceId, name: request.deviceName, publicKey: request.publicKey,
                transportType: source.rawValue, isTrusted: true)
            currentPairedDevice = device
            if let metadata = try? encoder.encode(device) { KeychainStore.save(key: "droiddock_paired_device_meta", data: metadata) }
            let response = PairingConfirmation(status: "accepted", deviceId: Host.current().localizedName ?? "Mac",
                deviceName: Host.current().localizedName ?? "Mac", publicKey: cryptoManager.localPublicKeyBase64,
                nonceResponse: request.pairingNonce)
            let json = String(data: try encoder.encode(response), encoding: .utf8)!
            sendRaw(try encoder.encode(MessageEnvelope(type: .pairingResponse, payload: json)), source: source)
        } catch { disconnect(source) }
    }

    private func loadPersistedDevice() {
        if let data = KeychainStore.load(key: "droiddock_paired_device_meta"), let device = try? decoder.decode(PairedDevice.self, from: data) {
            currentPairedDevice = device
        }
    }
    private func failPending() {
        let old = orderedPending; pending.removeAll(); pendingOrder.removeAll(); pendingBytes = 0
        old.forEach { $0.completion?(false) }
    }
    public func unpairDevice(notifyPhone: Bool = true) {
        queue.async {
            let token = UUID()
            self.unpairToken = token
            if notifyPhone {
                self.sendEnvelope(MessageEnvelope(type: .unpair, payload: "{}")) { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.unpairToken == token else { return }
                        self.clearPairing()
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 2) {
                    if self.unpairToken == token { self.clearPairing() }
                }
            } else { self.clearPairing() }
        }
    }
    private func clearPairing() {
        unpairToken = UUID()
        if let device = currentPairedDevice { cryptoManager.removePairedDevice(deviceId: device.id) }
        KeychainStore.delete(key: "droiddock_paired_device_meta")
        currentPairedDevice = nil; sessions.removeAll(); seen.reset()
        failPending(); disconnect(.wifi); disconnect(.bluetooth); updateTransport()
    }

    public func wifiTransportDidReceive(data: Data) { handleInboundData(data, source: .wifi) }
    public func bluetoothTransportDidReceive(data: Data) { handleInboundData(data, source: .bluetooth) }
    public func wifiTransportDidChangeState(isConnected: Bool) {
        queue.async {
            self.sessions.removeValue(forKey: .wifi)
            self.rawWiFiConnectedAt = isConnected ? Date() : nil
            self.updateTransport()
        }
    }
    public func bluetoothTransportDidChangeState(isConnected: Bool) {
        queue.async {
            self.sessions.removeValue(forKey: .bluetooth)
            self.rawBLEConnectedAt = isConnected ? Date() : nil
            self.updateTransport()
        }
    }
}
