import XCTest
@testable import DroidLink

final class MediaNotificationTests: XCTestCase {
    @MainActor func testBedtimeAndLegacyCachedFlagsDoNotBecomePlayers() {
        let state = AppState(startServices: false)
        state.activeTransport = .wifi
        let bedtime = AppNotification(id: "bedtime", packageName: "com.google.android.apps.wellbeing", appName: "Digital Wellbeing", title: "Bedtime mode", text: "Pause for 30 minutes", isMediaPlayback: true)
        state.receiveNotificationSync([bedtime])
        XCTAssertNil(state.activeMediaNotification)
        let player = AppNotification(id: "music", packageName: "test.player", appName: "Music", title: "Track", text: "Artist", isMediaPlayback: true, mediaSessionVerified: true)
        state.receiveNotificationSync([bedtime, player])
        XCTAssertEqual(state.activeMediaNotification?.id, "music")
        state.receiveNotificationRemoved(id: "music")
        XCTAssertNil(state.activeMediaNotification)
        state.receiveNotificationSync([player])
        state.activeTransport = .none
        state.updateActiveMediaNotification()
        XCTAssertNil(state.activeMediaNotification)
    }
}
