import XCTest
@testable import DroidLink

final class MirrorProtocolTests: XCTestCase {
    private let id = "00000000-0000-0000-0000-000000000001"
    private let key = Data(0..<32)
    func testAndroidCryptoWireVector() throws {
        let phone = try MirrorCipher(key: key, sessionId: id, isMac: false)
        let record = try phone.seal(Data([6]))
        XCTAssertEqual(record.map { String(format: "%02x", $0) }.joined(), "0000000000000001ad8f9d970d9226c138724a721fec8a0711")
        let mac = try MirrorCipher(key: key, sessionId: id)
        XCTAssertEqual(try mac.open(record), Data([6]))
        XCTAssertThrowsError(try mac.open(record))
        XCTAssertEqual(try phone.open(mac.seal(Data([3, 42]))), Data([3, 42]))
    }
    func testTamperingAndSessionBinding() throws {
        let phone = try MirrorCipher(key: key, sessionId: id, isMac: false)
        let record = try phone.seal(Data([1, 2, 3]))
        var tampered = record; tampered[tampered.count - 1] ^= 1
        let mac = try MirrorCipher(key: key, sessionId: id)
        XCTAssertThrowsError(try mac.open(tampered))
        XCTAssertEqual(try mac.open(record), Data([1, 2, 3])) // A failed tag must not advance sequence.
        let other = try MirrorCipher(key: key, sessionId: "00000000-0000-0000-0000-000000000002")
        XCTAssertThrowsError(try other.open(record))
        XCTAssertThrowsError(try MirrorCipher(key: key, sessionId: id, isMac: false).open(record))
        XCTAssertThrowsError(try MirrorCipher(key: Data(), sessionId: id))
    }
    func testRejectsMissingRecord() throws {
        let phone = try MirrorCipher(key: key, sessionId: id, isMac: false)
        _ = try phone.seal(Data([1]))
        let mac = try MirrorCipher(key: key, sessionId: id)
        XCTAssertThrowsError(try mac.open(phone.seal(Data([2]))))
    }
    func testH264Framing() {
        let annexB = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3])
        XCTAssertEqual(MirrorH264.nalUnits(annexB), [Data([0x67, 1, 2]), Data([0x68, 3])])
        let avcc = Data([0, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x68, 3])
        XCTAssertEqual(MirrorH264.nalUnits(avcc), MirrorH264.nalUnits(annexB))
        let config = Data([1, 0x64, 0, 0x1f, 0xff, 0xe1, 0, 3, 0x67, 1, 2, 1, 0, 2, 0x68, 3])
        XCTAssertEqual(MirrorH264.parameterSets(config), MirrorH264.nalUnits(annexB))
        XCTAssertEqual(MirrorH264.parameterSets(Data(config.dropLast())), [])
        XCTAssertEqual(MirrorH264.nalUnits(Data([0, 0, 0, 10, 0x65])), [])
    }
}
