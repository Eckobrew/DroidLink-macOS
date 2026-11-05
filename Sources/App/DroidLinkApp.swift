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
    @NSApplicationDelegateAdaptor(DroidLinkAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
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
        MenuBarExtra("Droid Link", systemImage: appState.activeTransport == .none ? "iphone.slash" : "iphone.radiowaves.left.and.right") {
            DroidLinkMenu().environmentObject(appState)
        }
    }
}

final class DroidLinkAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct DroidLinkMenu: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appState.pairedDevice?.name ?? "No phone paired")
        Text(appState.activeTransport == .none ? "Disconnected" : "Connected via \(appState.activeTransport.rawValue)")
        Divider()
        Button("Open Droid Link") { showWindow() }
        Button("Messages") { appState.selectedNavigation = .messages; showWindow() }
        Button("Calls") { appState.selectedNavigation = .calls; showWindow() }
        Divider()
        Button("Settings…") { appState.selectedNavigation = .settings; showWindow() }
        Divider()
        Button("Quit Droid Link") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
