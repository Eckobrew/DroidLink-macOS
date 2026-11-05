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

    func testAuthorizedUSBWinsBeforeWirelessDiscovery() {
        let serial = ScrcpyManager.selectAdbDevice(host: "192.168.1.107") { arguments in
            XCTAssertEqual(arguments, ["devices", "-l"])
            return """
            192.168.1.107:32791 device
            unauthorized-phone unauthorized usb:1-1
            usb-phone device usb:1-2
            """
        }
        XCTAssertEqual(serial, "usb-phone")
    }

    func testWirelessAliasesIdentifyOnePhoneWithoutCompanionWiFi() {
        let serial = ScrcpyManager.selectAdbDevice(host: nil) { arguments in
            if arguments == ["devices", "-l"] {
                return """
                phone._adb-tls-connect._tcp device
                192.168.1.107:32791 device
                usb-phone unauthorized usb:1-2
                """
            }
            XCTAssertEqual(arguments, ["mdns", "services"])
            return "phone _adb-tls-connect._tcp 192.168.1.107:32791"
        }
        XCTAssertEqual(serial, "phone._adb-tls-connect._tcp")
    }

    func testConnectOutputDoesNotCountAsAnAuthorizedDevice() {
        let serial = ScrcpyManager.selectAdbDevice(host: "192.168.1.107") { arguments in
            if arguments == ["devices", "-l"] { return "192.168.1.107:32791 offline" }
            if arguments == ["mdns", "services"] {
                return "phone _adb-tls-connect._tcp 192.168.1.107:32791"
            }
            XCTAssertEqual(arguments, ["connect", "192.168.1.107:32791"])
            return "connected to 192.168.1.107:32791"
        }
        XCTAssertNil(serial)
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
