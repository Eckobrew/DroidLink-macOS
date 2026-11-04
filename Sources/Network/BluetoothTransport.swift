import Foundation
@preconcurrency import CoreBluetooth

public protocol BluetoothTransportDelegate: AnyObject, Sendable {
    func bluetoothTransportDidReceive(data: Data)
    func bluetoothTransportDidChangeState(isConnected: Bool)
}

public final class BluetoothTransport: NSObject, @unchecked Sendable {
    public static var serviceUUID: CBUUID { CBUUID(string: "DF010001-B123-4ABC-9DEF-0123456789AB") }
    public static var rxCharUUID: CBUUID  { CBUUID(string: "DF010002-B123-4ABC-9DEF-0123456789AB") } // Android -> Mac
    public static var txCharUUID: CBUUID  { CBUUID(string: "DF010003-B123-4ABC-9DEF-0123456789AB") } // Mac -> Android

    public weak var delegate: BluetoothTransportDelegate?
    public private(set) var isConnected: Bool = false

    private var peripheralManager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var connectedCentral: CBCentral?
    private let queue = DispatchQueue(label: "com.droiddock.bluetooth", qos: .userInitiated)

    // Reassembly buffers: CentralID -> (totalChunks, expected, chunks)
    private var inboundChunks: [UUID: [Int: Data]] = [:]
    private var inboundTotals: [UUID: Int] = [:]

    public override init() {
        super.init()
    }

    public func startAdvertising() {
        queue.async {
            if self.peripheralManager == nil {
                self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.peripheralManager?.stopAdvertising()
            self.peripheralManager = nil
            self.isConnected = false
            self.connectedCentral = nil
            self.delegate?.bluetoothTransportDidChangeState(isConnected: false)
        }
    }

    public func send(data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async {
            guard let tx = self.txCharacteristic, let central = self.connectedCentral, self.isConnected else {
                completion?(NSError(domain: "BluetoothTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active Bluetooth central connected"]))
                return
            }

            // Chunk data into 500-byte segments (standard safe BLE 5.0 MTU)
            let chunkSize = 500
            let totalChunks = Int(ceil(Double(data.count) / Double(chunkSize)))

            for i in 0..<totalChunks {
                let start = i * chunkSize
                let end = min(start + chunkSize, data.count)
                let subdata = data.subdata(in: start..<end)

                var packet = Data([UInt8(i), UInt8(totalChunks)])
                packet.append(subdata)

                let didSend = self.peripheralManager?.updateValue(packet, for: tx, onSubscribedCentrals: [central]) ?? false
                if !didSend {
                    // Queue full, small yield
                    Thread.sleep(forTimeInterval: 0.01)
                    _ = self.peripheralManager?.updateValue(packet, for: tx, onSubscribedCentrals: [central])
                }
            }
            completion?(nil)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate
extension BluetoothTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            let rx = CBMutableCharacteristic(
                type: Self.rxCharUUID,
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )

            let tx = CBMutableCharacteristic(
                type: Self.txCharUUID,
                properties: [.notify, .read],
                value: nil,
                permissions: [.readable]
            )
            self.txCharacteristic = tx

            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [rx, tx]

            peripheral.add(service)
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                CBAdvertisementDataLocalNameKey: "Droid Link"
            ])
            print("[BluetoothTransport] Advertising BLE GATT service")
        } else {
            print("[BluetoothTransport] Bluetooth state: \(peripheral.state.rawValue)")
            isConnected = false
            delegate?.bluetoothTransportDidChangeState(isConnected: false)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.txCharUUID {
            print("[BluetoothTransport] Central subscribed to TX: \(central.identifier)")
            connectedCentral = central
            isConnected = true
            delegate?.bluetoothTransportDidChangeState(isConnected: true)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.txCharUUID {
            print("[BluetoothTransport] Central unsubscribed from TX: \(central.identifier)")
            if connectedCentral?.identifier == central.identifier {
                connectedCentral = nil
                isConnected = false
                delegate?.bluetoothTransportDidChangeState(isConnected: false)
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == Self.rxCharUUID, let val = request.value, val.count >= 2 {
                let chunkIdx = Int(val[0])
                let totalChunks = Int(val[1])
                let payload = val.subdata(in: 2..<val.count)
                let centralId = request.central.identifier

                if inboundChunks[centralId] == nil {
                    inboundChunks[centralId] = [:]
                    inboundTotals[centralId] = totalChunks
                }

                inboundChunks[centralId]?[chunkIdx] = payload

                if let currentChunks = inboundChunks[centralId], currentChunks.count == totalChunks {
                    // Reassemble in order
                    var assembled = Data()
                    for idx in 0..<totalChunks {
                        if let part = currentChunks[idx] {
                            assembled.append(part)
                        }
                    }
                    inboundChunks.removeValue(forKey: centralId)
                    inboundTotals.removeValue(forKey: centralId)

                    delegate?.bluetoothTransportDidReceive(data: assembled)
                }

                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
}
