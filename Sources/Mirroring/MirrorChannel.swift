import Foundation
import Network

/// All mutable transport/crypto state is confined to queue.
final class MirrorChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.droiddock.mirror.media", qos: .userInteractive)
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var selected: UUID?
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var lastReceived = Date()
    private var sending = false
    private var pendingInputs: [Data] = []
    private let sessionId: String
    private let key: Data
    private let message: @Sendable (UInt8, Data) -> Void
    private let failure: @Sendable (String) -> Void
    private final class Peer: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        let cipher: MirrorCipher
        var authenticated = false
        init(_ connection: NWConnection, key: Data, sessionId: String) throws {
            self.connection = connection
            cipher = try MirrorCipher(key: key, sessionId: sessionId)
        }
    }
    init(sessionId: String, key: Data, message: @escaping @Sendable (UInt8, Data) -> Void,
         failure: @escaping @Sendable (String) -> Void) {
        self.sessionId = sessionId; self.key = key; self.message = message; self.failure = failure
    }
    func start(ready: @escaping @Sendable (UInt16) -> Void) {
        queue.async {
            do {
                let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
                let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.stopped else { return }
                    if case .ready = state, let port = listener.port { ready(port.rawValue) }
                    if case .failed(let error) = state { self.fail(error.localizedDescription) }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
            } catch { self.fail(error.localizedDescription) }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, selected == nil, peers.count < 4,
              let peer = try? Peer(connection, key: key, sessionId: sessionId) else { connection.cancel(); return }
        peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            if case .ready = state { self.readHeader(peer) }
            if case .failed = state { self.drop(peer, reason: "The phone disconnected") }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak peer] in
            guard let self, let peer, !peer.authenticated else { return }
            self.drop(peer, reason: "Media authentication timed out")
        }
    }
    private func read(_ peer: Peer, count: Int, accumulated: Data = Data(), completion: @escaping @Sendable (Data) -> Void) {
        guard !stopped, peers[peer.id] != nil else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, !self.stopped else { return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if bytes.count == count { completion(bytes) }
            else if error != nil || complete { self.drop(peer, reason: "The phone closed the media connection") }
            else { self.read(peer, count: count, accumulated: bytes, completion: completion) }
        }
    }
    private func readHeader(_ peer: Peer) {
        read(peer, count: 4) { [weak self, weak peer] header in
            guard let self, let peer else { return }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 25, length <= MirrorCipher.maximumRecordSize else { self.drop(peer, reason: "Invalid media record length"); return }
            self.read(peer, count: Int(length)) { [weak self, weak peer] record in
                guard let self, let peer else { return }
                do {
                    let plaintext = try peer.cipher.open(record)
                    guard let kind = plaintext.first else { throw CryptoError.decryptionFailed }
                    let payload = Data(plaintext.dropFirst())
                    if !peer.authenticated {
                        guard kind == 2,
                              let metadata = try? JSONDecoder().decode(MirrorMetadata.self, from: payload),
                              metadata.sessionId == self.sessionId else { throw CryptoError.decryptionFailed }
                        peer.authenticated = true; self.selected = peer.id
                        self.listener?.cancel(); self.listener = nil
                        for other in Array(self.peers.values) where other.id != peer.id { self.drop(other, reason: "") }
                        self.startHeartbeat()
                    }
                    self.lastReceived = Date()
                    self.message(kind, payload)
                    self.readHeader(peer)
                } catch { self.drop(peer, reason: "Media authentication failed") }
            }
        }
    }
    private func startHeartbeat() {
        lastReceived = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) > 15 { self.fail("The phone stopped responding"); return }
            self.enqueue(Data("{\"action\":\"ping\"}".utf8))
        }
        self.timer = timer; timer.resume()
    }
    func send(_ command: Data) { queue.async { self.enqueue(command) } }
    private func enqueue(_ command: Data) {
        guard !stopped, selected != nil, command.count <= 8192 else { return }
        guard pendingInputs.count < 64 else { fail("The control connection is too slow. Reconnect to continue."); return }
        pendingInputs.append(command)
        flushInput()
    }
    private func flushInput() {
        guard !sending, !pendingInputs.isEmpty, let id = selected, let peer = peers[id], !stopped else { return }
        do {
            let record = try peer.cipher.seal(Data([3]) + pendingInputs.removeFirst())
            var length = UInt32(record.count).bigEndian
            let packet = withUnsafeBytes(of: &length) { Data($0) } + record
            sending = true
            peer.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.sending = false
                if let error { self.fail(error.localizedDescription) } else { self.flushInput() }
            })
        } catch { fail(error.localizedDescription) }
    }
    private func drop(_ peer: Peer, reason: String) {
        peers.removeValue(forKey: peer.id); peer.connection.cancel()
        if selected == peer.id { fail(reason) }
    }
    private func fail(_ reason: String) {
        guard !stopped else { return }
        close(); failure(reason)
    }
    private func close() {
        stopped = true
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll(); selected = nil; pendingInputs.removeAll()
    }
    func perform(_ operation: @escaping @Sendable () -> Void) { queue.async(execute: operation) }
    func stop() { queue.async { self.close() } }
}
