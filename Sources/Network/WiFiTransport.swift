import Foundation
import Network

public protocol WiFiTransportDelegate: AnyObject, Sendable {
    func wifiTransportDidReceive(data: Data)
    func wifiTransportDidChangeState(isConnected: Bool)
}

public final class WiFiTransport: @unchecked Sendable {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.droiddock.wifi", qos: .userInitiated)
    public weak var delegate: WiFiTransportDelegate?
    public private(set) var isConnected: Bool = false
    public private(set) var remoteHost: String? = nil
    public let port: UInt16

    public init(port: UInt16 = 8765) {
        self.port = port
    }

    public func startListening() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 8765)
        listener = try NWListener(using: params, on: nwPort)

        // Advertise Bonjour service for seamless local discovery
        listener?.service = NWListener.Service(name: "DroidDock-\(Host.current().localizedName ?? "Mac")", type: "_droiddock._tcp")

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[WiFiTransport] NWListener ready on port \(self?.port ?? 0)")
            case .failed(let error):
                print("[WiFiTransport] NWListener failed: \(error)")
                self?.listener?.cancel()
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        listener?.start(queue: queue)
    }

    public func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        isConnected = false
        delegate?.wifiTransportDidChangeState(isConnected: false)
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection

        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let addr):
                self.remoteHost = "\(addr)"
            default:
                break
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
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
            isConnected = false
            remoteHost = nil
            delegate?.wifiTransportDidChangeState(isConnected: false)
        }
    }

    private func receiveExact(count: Int, accumulated: Data = Data(), on connection: NWConnection, completion: @escaping (Data?) -> Void) {
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
                if isComplete {
                    completion(nil)
                }
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

            let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard length > 0 && length < 25_000_000 else {
                self.cleanupConnection(connection)
                return
            }

            self.receiveExact(count: length, on: connection) { [weak self] payloadData in
                guard let self = self, let payload = payloadData, payload.count == length else {
                    self?.cleanupConnection(connection)
                    return
                }

                self.delegate?.wifiTransportDidReceive(data: payload)
                self.receiveNextMessage(on: connection)
            }
        }
    }

    public func send(data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        guard let connection = activeConnection, isConnected else {
            completion?(NSError(domain: "WiFiTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active Wi-Fi connection"]))
            return
        }

        var framedData = Data()
        var lengthBE = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { framedData.append(contentsOf: $0) }
        framedData.append(data)

        connection.send(content: framedData, completion: .contentProcessed { error in
            completion?(error)
        })
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
