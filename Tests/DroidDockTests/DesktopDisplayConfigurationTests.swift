import XCTest
@testable import DroidLink

final class DesktopDisplayConfigurationTests: XCTestCase {
    func testWindowedDesktopRequests1080pWithoutFullScreen() {
        let arguments = DesktopDisplayConfiguration.windowed1080p.arguments
        XCTAssertTrue(arguments.contains("--new-display=1920x1080/160"))
        XCTAssertFalse(arguments.contains("--fullscreen"))
        XCTAssertFalse(arguments.contains("--flex-display"))
        XCTAssertTrue(arguments.contains("--no-vd-destroy-content"))
        XCTAssertTrue(arguments.contains("--keyboard=uhid"))
        XCTAssertTrue(arguments.contains("--display-ime-policy=hide"))
    }
    func testFullScreenDesktopUsesTargetWorkspaceSize() {
        let configuration = DesktopDisplayConfiguration(width: 2560, height: 1600, fullScreen: true)
        XCTAssertTrue(configuration.arguments.contains("--new-display=2560x1600/160"))
        XCTAssertTrue(configuration.arguments.contains("--fullscreen"))
        XCTAssertTrue(configuration.arguments.contains("--window-borderless"))
        XCTAssertFalse(configuration.arguments.contains("--flex-display"))
        let odd = DesktopDisplayConfiguration(width: 2559, height: 1599, fullScreen: true)
        XCTAssertEqual(odd.width, 2558)
        XCTAssertEqual(odd.height, 1598)
    }
    func testAspectRatioPolicyAndExternalDisplayPlacement() {
        let scaled = DesktopDisplayConfiguration.fullScreenForWorkspace(width: 1680, height: 1050)
        XCTAssertTrue(scaled.arguments.contains("--new-display=1920x1200/160"))
        XCTAssertEqual(DesktopDisplayConfiguration.fullScreenForWorkspace(width: 2560, height: 1600).height, 1200)
        let external = DesktopDisplayConfiguration.fullScreenForWorkspace(width: 1920, height: 1080, windowX: 1760, windowY: 300)
        XCTAssertTrue(external.arguments.contains("--new-display=1920x1080/160"))
        XCTAssertTrue(external.arguments.contains("--window-x=1760"))
        XCTAssertTrue(external.arguments.contains("--window-y=300"))
    }
}
