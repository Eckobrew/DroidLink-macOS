import XCTest
@testable import DroidLink

final class MirrorVideoPacketTests: XCTestCase {
    private let vector: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 0, 4, 210, 0, 0, 0, 5, 0, 0, 0, 1, 0x65]

    func testAndroidWireVector() throws {
        let packet = try MirrorVideoPacket(encoded: Data(vector))
        XCTAssertEqual(packet.kind, .keyFrame)
        XCTAssertEqual(packet.presentationTimeUs, 1234)
        XCTAssertEqual(packet.payload, Data([0, 0, 0, 1, 0x65]))
    }

    func testRejectsMalformedPackets() {
        for count in 0..<vector.count {
            XCTAssertThrowsError(try MirrorVideoPacket(encoded: Data(vector.prefix(count))))
        }
        var invalid = vector
        invalid[0] = 2
        XCTAssertThrowsError(try MirrorVideoPacket(encoded: Data(invalid)))
        invalid = vector
        invalid[1] = 3
        XCTAssertThrowsError(try MirrorVideoPacket(encoded: Data(invalid)))
        invalid = vector
        invalid[10] = 0x7f
        XCTAssertThrowsError(try MirrorVideoPacket(encoded: Data(invalid)))
        XCTAssertThrowsError(try MirrorVideoPacket(encoded: Data(vector + [0])))
    }
}
