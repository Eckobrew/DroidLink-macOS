import XCTest
@testable import DroidLink

final class BLETransportTests: XCTestCase {
    func testFramingMatchesAndroidWireVector() throws {
        let frame = try BLEFrameDecoder.encode(Data([0, 1, 2, 255, 65]))
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(), "00000005000102ff41")
    }
    func testLargeFramesAtDifferentATTBoundaries() throws {
        let payload = Data((0..<260_000).map { UInt8($0 % 251) })
        let encoded = try BLEFrameDecoder.encode(payload)
        for mtu in [1, 7, 20, 182, 244, 512] {
            var decoder = BLEFrameDecoder()
            var decoded: [Data] = []
            for start in stride(from: 0, to: encoded.count, by: mtu) {
                decoded += try decoder.append(encoded.subdata(in: start..<min(start + mtu, encoded.count)))
            }
            XCTAssertEqual(decoded, [payload], "ATT payload \(mtu)")
        }
    }
    func testCoalescedFramesAndSplitHeader() throws {
        let first = try BLEFrameDecoder.encode(Data("first".utf8))
        let second = try BLEFrameDecoder.encode(Data("second".utf8))
        var decoder = BLEFrameDecoder()
        XCTAssertTrue(try decoder.append(first.prefix(3)).isEmpty)
        XCTAssertEqual(try decoder.append(Data(first.dropFirst(3)) + second), [Data("first".utf8), Data("second".utf8)])
    }
    func testMalformedLengthsAndDisconnectReset() throws {
        for header in [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 128, 0, 1])] {
            var decoder = BLEFrameDecoder()
            XCTAssertThrowsError(try decoder.append(header))
            XCTAssertEqual(try decoder.append(BLEFrameDecoder.encode(Data([42]))), [Data([42])])
        }
        var decoder = BLEFrameDecoder()
        _ = try decoder.append(Data([0, 0, 0, 9, 1]))
        decoder.reset()
        XCTAssertEqual(try decoder.append(BLEFrameDecoder.encode(Data([2, 3]))), [Data([2, 3])])
    }
    func testBackpressureDoesNotAdvanceOrDropChunks() throws {
        let data = Data(repeating: 65, count: 150_000)
        let id = UUID()
        var queue = BLEFrameQueue()
        try queue.enqueue(data, id: id)
        XCTAssertEqual(queue.peek(maximumLength: 20), queue.peek(maximumLength: 20))
        var bytes = Data()
        var completions: [UUID] = []
        while let chunk = queue.peek(maximumLength: 20) {
            bytes.append(chunk)
            if let completed = queue.commit(chunk.count) { completions.append(completed) }
        }
        XCTAssertEqual(bytes, try BLEFrameDecoder.encode(data))
        XCTAssertEqual(completions, [id])
        XCTAssertEqual(queue.remainingBytes, 0)
    }
    func testQueueIsBoundedAndResetDropsPartialFrame() throws {
        var queue = BLEFrameQueue()
        try queue.enqueue(Data(repeating: 1, count: BLEFrameDecoder.maximumFrameSize), id: UUID())
        XCTAssertThrowsError(try queue.enqueue(Data(repeating: 2, count: BLEFrameDecoder.maximumFrameSize), id: UUID()))
        queue.reset()
        XCTAssertNil(queue.peek(maximumLength: 20))
        XCTAssertThrowsError(try queue.enqueue(Data(), id: UUID()))
    }
    func testTransportPreferenceAndRetryDeduplication() {
        XCTAssertEqual(ActiveTransport.preferred(wifi: true, bluetooth: true), .wifi)
        XCTAssertEqual(ActiveTransport.preferred(wifi: false, bluetooth: true), .bluetooth)
        XCTAssertEqual(ActiveTransport.preferred(wifi: true, bluetooth: true), .wifi)
        XCTAssertEqual(ActiveTransport.preferred(wifi: false, bluetooth: true, fallbackEnabled: false), .none)
        var ids = EnvelopeDeduplicator(capacity: 2)
        XCTAssertTrue(ids.insert("send-command"))
        XCTAssertFalse(ids.insert("send-command")) // The BLE retry of the original Wi-Fi command.
        XCTAssertTrue(ids.insert("next")); XCTAssertTrue(ids.insert("third"))
        XCTAssertTrue(ids.insert("send-command")) // Bounded memory, not unlimited persistence.
    }
    func testATTBatchAcceptsLongWritesAndIndependentWrites() throws {
        XCTAssertEqual(try BLEWriteBatch.flatten([(0, Data([1, 2])), (2, Data([3, 4]))]), Data([1, 2, 3, 4]))
        XCTAssertEqual(try BLEWriteBatch.flatten([(0, Data([1, 2])), (0, Data([3, 4]))]), Data([1, 2, 3, 4]))
    }
    func testATTBatchRejectsMissingAndOverlappingFragments() {
        XCTAssertThrowsError(try BLEWriteBatch.flatten([(1, Data([1]))]))
        XCTAssertThrowsError(try BLEWriteBatch.flatten([(0, Data([1, 2])), (1, Data([3]))]))
        XCTAssertThrowsError(try BLEWriteBatch.flatten([(0, Data(repeating: 1, count: 513))]))
    }
    func testIndependentTransportSessionsAndReconnectionKeys() throws {
        let senderWiFi = CryptoManager(), receiverWiFi = CryptoManager()
        let senderBLE = CryptoManager(), receiverBLE = CryptoManager()
        let id = "transport-test"
        func pair(_ sender: CryptoManager, _ receiver: CryptoManager, _ salt: String) throws {
            try sender.establishSharedKey(deviceId: id, remotePublicKeyBase64: receiver.localPublicKeyBase64, salt: salt, persistPeer: false)
            try receiver.establishSharedKey(deviceId: id, remotePublicKeyBase64: sender.localPublicKeyBase64, salt: salt, persistPeer: false)
        }
        try pair(senderWiFi, receiverWiFi, "DroidDock_E2EE_v2:wifi:nonce-1")
        try pair(senderBLE, receiverBLE, "DroidDock_E2EE_v2:bluetooth:nonce-2")
        let first = try senderWiFi.encrypt(deviceId: id, plaintext: Data("wifi".utf8))
        XCTAssertEqual(try receiverWiFi.decrypt(deviceId: id, packet: first), Data("wifi".utf8))
        let fallback = try senderBLE.encrypt(deviceId: id, plaintext: Data("ble".utf8))
        XCTAssertEqual(try receiverBLE.decrypt(deviceId: id, packet: fallback), Data("ble".utf8))
        XCTAssertThrowsError(try receiverWiFi.decrypt(deviceId: id, packet: fallback))
        try pair(senderWiFi, receiverWiFi, "DroidDock_E2EE_v2:wifi:nonce-3")
        XCTAssertThrowsError(try receiverWiFi.decrypt(deviceId: id, packet: first))
        let continuedBLE = try senderBLE.encrypt(deviceId: id, plaintext: Data("still ble".utf8))
        XCTAssertEqual(try receiverBLE.decrypt(deviceId: id, packet: continuedBLE), Data("still ble".utf8))
    }
}
