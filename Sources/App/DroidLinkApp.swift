import SwiftUI

@main
struct DroidLinkLauncher {
    static func main() {
        if ProcessInfo.processInfo.environment["DROIDLINK_TRANSPORT_PROBE"] == "1" {
            Task { @MainActor in await TransportProbe().run() }
            RunLoop.main.run()
        } else { DroidLinkApp.main() }
    }
}

struct DroidLinkApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 850, minHeight: 550)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Message...") {
                    appState.selectedNavigation = .messages
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open Dialer") {
                    appState.selectedNavigation = .calls
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Pair Phone...") {
                    appState.selectedNavigation = .settings
                }
                .keyboardShortcut("p", modifiers: [.command])
            }
        }
    }
}
