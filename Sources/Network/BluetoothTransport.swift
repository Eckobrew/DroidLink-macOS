import Foundation
@preconcurrency import CoreBluetooth

public protocol BluetoothTransportDelegate: AnyObject, Sendable {
    func bluetoothTransportDidReceive(data: Data)
    func bluetoothTransportDidChangeState(isConnected: Bool)
}

public final class BluetoothTransport: NSObject, @unchecked Sendable {
    public static var serviceUUID: CBUUID { CBUUID(string: "DF010001-B123-4ABC-9DEF-0123456789AB") }
    public static var rxCharUUID: CBUUID { CBUUID(string: "DF010002-B123-4ABC-9DEF-0123456789AB") }
    public static var txCharUUID: CBUUID { CBUUID(string: "DF010003-B123-4ABC-9DEF-0123456789AB") }
    public weak var delegate: BluetoothTransportDelegate?
    private let stateLock = NSLock()
    private var connected = false
    private var activity = Date.distantPast
    public var lastActivity: Date { stateLock.withLock { activity } }
    private func recordActivity() { stateLock.withLock { activity = Date() } }
    public var isConnected: Bool { stateLock.withLock { connected } }
    private let queue = DispatchQueue(label: "com.droiddock.bluetooth", qos: .userInitiated)
    private var manager: CBPeripheralManager?
    private var tx: CBMutableCharacteristic?
    private var central: CBCentral?
    private var decoder = BLEFrameDecoder()
    private var outgoing = BLEFrameQueue()
    private var completions: [UUID: @Sendable (Error?) -> Void] = [:]
    private var lastProgress = Date()
    private var watchdog: DispatchSourceTimer?

    private func setConnected(_ value: Bool) {
        let changed = stateLock.withLock { let old = connected; connected = value; return old != value }
        if changed { delegate?.bluetoothTransportDidChangeState(isConnected: value) }
    }

    public func startAdvertising() {
        queue.async {
            guard self.manager == nil else { return }
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self, !self.outgoing.isEmpty, Date().timeIntervalSince(self.lastProgress) > 30 else { return }
                self.resetPeer(error: self.failure("Bluetooth send stalled"))
            }
            self.watchdog = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async {
            self.watchdog?.cancel(); self.watchdog = nil
            self.manager?.stopAdvertising()
            self.manager?.removeAllServices()
            self.resetPeer(error: self.failure("Bluetooth stopped"))
            self.manager = nil; self.tx = nil
        }
    }

    public func disconnect() { queue.async { self.resetPeer(error: self.failure("Bluetooth disconnected")) } }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BluetoothTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func resetPeer(error: Error) {
        print("[BluetoothTransport] Reset peer: \(error.localizedDescription)")
        central = nil
        decoder.reset(); outgoing.reset()
        let callbacks = Array(completions.values)
        completions.removeAll()
        setConnected(false)
        callbacks.forEach { $0(error) }
    }

    public func send(data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async {
            guard self.central != nil, self.tx != nil, self.isConnected else {
                completion?(self.failure("No Bluetooth subscriber")); return
            }
            do {
                let id = UUID()
                let wasEmpty = self.outgoing.isEmpty
                try self.outgoing.enqueue(data, id: id)
                if let completion { self.completions[id] = completion }
                if wasEmpty { self.lastProgress = Date() }
                self.drain()
            } catch { completion?(error) }
        }
    }

    private func drain() {
        guard let manager, let central, let tx else { return }
        let maximum = min(512, central.maximumUpdateValueLength)
        while let chunk = outgoing.peek(maximumLength: maximum) {
            guard manager.updateValue(chunk, for: tx, onSubscribedCentrals: [central]) else { return }
            lastProgress = Date()
            recordActivity()
            if let id = outgoing.commit(chunk.count) { completions.removeValue(forKey: id)?(nil) }
        }
    }
}

extension BluetoothTransport: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("[BluetoothTransport] Peripheral state: \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else {
            tx = nil
            resetPeer(error: failure("Bluetooth is unavailable"))
            return
        }
        peripheral.removeAllServices()
        let rx = CBMutableCharacteristic(type: Self.rxCharUUID, properties: [.write], value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(type: Self.txCharUUID, properties: [.notify], value: nil, permissions: [])
        self.tx = tx
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [rx, tx]
        peripheral.add(service)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        print("[BluetoothTransport] Advertising: \(error?.localizedDescription ?? "ready")")
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { drain() }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.txCharUUID else { return }
        print("[BluetoothTransport] Subscriber ATT payload: \(central.maximumUpdateValueLength)")
        if let current = self.central, current.identifier != central.identifier { return }
        if self.central != nil { resetPeer(error: failure("Bluetooth subscription restarted")) }
        decoder.reset()
        self.central = central
        setConnected(true)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if central.identifier == self.central?.identifier { resetPeer(error: failure("Phone unsubscribed")) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == Self.rxCharUUID && $0.central.identifier == central?.identifier }) else {
            peripheral.respond(to: first, withResult: .insufficientAuthorization)
            return
        }
        do {
            let parts = try requests.map { request -> (offset: Int, value: Data) in
                guard let value = request.value else { throw BLEFrameError.invalidLength }
                return (request.offset, value)
            }
            let bytes = try BLEWriteBatch.flatten(parts)
            recordActivity()
            let frames = try decoder.append(bytes)
            peripheral.respond(to: first, withResult: .success)
            frames.forEach { delegate?.bluetoothTransportDidReceive(data: $0) }
        } catch {
            peripheral.respond(to: first, withResult: .invalidPdu)
            resetPeer(error: error)
        }
    }
}
