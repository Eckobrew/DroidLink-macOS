import XCTest
@testable import DroidLink

final class ScrcpyManagerTests: XCTestCase {
    func testWirelessEndpointUsesConnectionServiceForRequestedPhone() {
        let services = """
        List of discovered mdns services
        other _adb-tls-connect._tcp 192.168.1.10:30000
        pairing _adb-tls-pairing._tcp 192.168.1.107:31000
        phone _adb-tls-connect._tcp 192.168.1.107:32791
        """
        XCTAssertEqual(ScrcpyManager.wirelessEndpoint(in: services, host: "192.168.1.107"), "192.168.1.107:32791")
        XCTAssertNil(ScrcpyManager.wirelessEndpoint(in: services, host: "192.168.1.1"))
    }

    func testDevelopmentResourcesAreResolvedFromCurrentCheckout() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/scrcpy")
        let manager = ScrcpyManager()
        XCTAssertEqual(try XCTUnwrap(manager.getScrcpyExecutablePath()), resources.appendingPathComponent("scrcpy").path)
        XCTAssertEqual(try XCTUnwrap(manager.getAdbExecutablePath()), resources.appendingPathComponent("adb").path)
        XCTAssertEqual(try XCTUnwrap(manager.getScrcpyServerPath()), resources.appendingPathComponent("scrcpy-server").path)
    }
}
