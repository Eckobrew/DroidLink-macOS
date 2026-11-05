import Foundation
import Network

public protocol WiFiTransportDelegate: AnyObject, Sendable {
    func wifiTransportDidReceive(data: Data)
    func wifiTransportDidChangeState(isConnected: Bool)
}

public final class WiFiTransport: @unchecked Sendable {
    private var listener: NWListener?
    private var listeningRequested = false
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.droiddock.wifi", qos: .userInitiated)
    public weak var delegate: WiFiTransportDelegate?
    private let stateLock = NSLock()
    private var connected = false
    private var host: String?
    public private(set) var isConnected: Bool {
        get { stateLock.withLock { connected } }
        set { stateLock.withLock { connected = newValue } }
    }
    public private(set) var remoteHost: String? {
        get { stateLock.withLock { host } }
        set { stateLock.withLock { host = newValue } }
    }
    public let port: UInt16

    public init(port: UInt16 = 8765) {
        self.port = port
    }

    public func startListening() throws {
        try queue.sync {
            listeningRequested = true
            guard listener == nil else { return }
            do { try createListener() }
            catch { scheduleListenerRecovery(); throw error }
        }
    }

    private func createListener() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 1
        tcpOptions.keepaliveCount = 2
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 8765)
        let newListener = try NWListener(using: params, on: nwPort)
        listener = newListener

        // Advertise Bonjour service for seamless local discovery
        listener?.service = NWListener.Service(name: "DroidDock-\(Host.current().localizedName ?? "Mac")", type: "_droiddock._tcp")

        listener?.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, self.listener === newListener else { return }
            switch state {
            case .ready:
                print("[WiFiTransport] NWListener ready on port \(self.port)")
            case .failed(let error):
                print("[WiFiTransport] NWListener failed: \(error)")
                self.listener = nil
                newListener.cancel()
                self.scheduleListenerRecovery()
            case .cancelled:
                self.listener = nil
                self.scheduleListenerRecovery()
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        listener?.start(queue: queue)
    }

    private func scheduleListenerRecovery() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.listeningRequested, self.listener == nil else { return }
            do { try self.createListener() }
            catch {
                print("[WiFiTransport] Listener restart failed: \(error)")
                self.scheduleListenerRecovery()
            }
        }
    }

    public func stop() {
        queue.async {
            self.listeningRequested = false
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.listener?.cancel(); self.listener = nil
            self.isConnected = false; self.remoteHost = nil
            self.delegate?.wifiTransportDidChangeState(isConnected: false)
        }
    }

    public func disconnectActiveConnection() {
        queue.async { [weak self] in
            guard let self = self, let connection = self.activeConnection else { return }
            print("[WiFiTransport] Disconnecting active connection by watchdog/unpair")
            connection.cancel()
            self.cleanupConnection(connection)
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection
        remoteHost = nil

        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let addr):
                self.remoteHost = "\(addr)"
            default:
                break
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.activeConnection === connection else { return }
            switch state {
            case .ready:
                print("[WiFiTransport] Client connected via Wi-Fi")
                self.isConnected = true
                self.delegate?.wifiTransportDidChangeState(isConnected: true)
                self.receiveNextMessage(on: connection)
            case .failed(let error):
                print("[WiFiTransport] Connection failed: \(error)")
                self.cleanupConnection(connection)
            case .cancelled:
                print("[WiFiTransport] Connection cancelled")
                self.cleanupConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func cleanupConnection(_ connection: NWConnection) {
        if activeConnection === connection {
            activeConnection = nil
            connection.cancel()
            isConnected = false
            remoteHost = nil
            delegate?.wifiTransportDidChangeState(isConnected: false)
        }
    }

    private func receiveExact(count: Int, accumulated: Data = Data(), on connection: NWConnection, completion: @escaping @Sendable (Data?) -> Void) {
        guard activeConnection === connection else { completion(nil); return }
        let remaining = count - accumulated.count
        guard remaining > 0 else {
            completion(accumulated)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] content, _, isComplete, error in
            if let error = error {
                print("[WiFiTransport] receive error: \(error)")
                completion(nil)
                return
            }
            guard let data = content, !data.isEmpty else {
                if isComplete { completion(nil) }
                else { self?.receiveExact(count: count, accumulated: accumulated, on: connection, completion: completion) }
                return
            }

            var nextAccum = accumulated
            nextAccum.append(data)
            if nextAccum.count >= count {
                completion(nextAccum)
            } else {
                self?.receiveExact(count: count, accumulated: nextAccum, on: connection, completion: completion)
            }
        }
    }

    private func receiveNextMessage(on connection: NWConnection) {
        receiveExact(count: 4, on: connection) { [weak self] lengthData in
            guard let self = self, let data = lengthData, data.count == 4 else {
                self?.cleanupConnection(connection)
                return
            }

            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard length > 0 && length <= BLEFrameDecoder.maximumFrameSize else {
                self.cleanupConnection(connection)
                return
            }

            self.receiveExact(count: length, on: connection) { [weak self] payloadData in
                guard let self = self, let payload = payloadData, payload.count == length else {
                    self?.cleanupConnection(connection)
                    return
                }

                guard self.activeConnection === connection else { return }
                self.delegate?.wifiTransportDidReceive(data: payload)
                self.receiveNextMessage(on: connection)
            }
        }
    }

    public func send(data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async {
            guard let connection = self.activeConnection, self.isConnected,
                  let framed = try? BLEFrameDecoder.encode(data) else {
                completion?(NSError(domain: "WiFiTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active Wi-Fi connection or invalid frame"]))
                return
            }
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.cleanupConnection(connection) }
                completion?(error)
            })
        }
    }

    /// Fetches all active non-loopback local IPv4 and IPv6 network addresses for QR code generation
    public static func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            // Check if interface is UP, RUNNING, and not LOOPBACK
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                        if !addresses.contains(ip) {
                            addresses.append(ip)
                        }
                    }
                }
            }
        }
        return addresses
    }
}
