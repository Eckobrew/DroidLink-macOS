import SwiftUI

@main
struct DroidLinkLauncher {
    static func main() {
        if ProcessInfo.processInfo.environment["DROIDLINK_HANDSFREE_HELPER"] == "1" {
            HandsFreeWorker.run()
        } else if ProcessInfo.processInfo.environment["DROIDLINK_TRANSPORT_PROBE"] == "1" {
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
                .background(MirrorMainWindowAnchor())
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

                Button("Close Stream") { NativeMirrorManager.shared.closeStreams() }
                    .keyboardShortcut("q", modifiers: [.control, .option, .shift])
                Button("Mirror Screen") { NativeMirrorManager.shared.start() }
                Menu("Desktop Mode (ADB)") {
                    Button("Windowed — 1080p") { NativeMirrorManager.shared.startDesktop(mode: .windowed1080p) }
                    Button("Full screen — New Space") { NativeMirrorManager.shared.startDesktop(mode: .fullScreen) }
                }

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
    func applicationDidFinishLaunching(_ notification: Notification) { StreamCloseShortcut.shared.register() }
    func applicationWillTerminate(_ notification: Notification) {
        NativeMirrorManager.shared.stop()
        ScrcpyManager.shared.terminateSession()
        ScrcpyManager.shared.stopAudioHandoff()
        CallAudioManager.shared.shutdown()
        StreamCloseShortcut.shared.unregister()
    }
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
        Button("Mirror Screen") { NativeMirrorManager.shared.start() }
        Menu("Desktop Mode (ADB)") {
            Button("Windowed — 1080p") { NativeMirrorManager.shared.startDesktop(mode: .windowed1080p) }
            Button("Full screen — New Space") { NativeMirrorManager.shared.startDesktop(mode: .fullScreen) }
        }
        Button("Mirror with phone display off (ADB)") {
            NativeMirrorManager.shared.stop()
            ScrcpyManager.shared.launchScrcpy(phoneIp: appState.connectedIp, turnScreenOff: true)
        }
        Button("Mirror with scrcpy (ADB)") { ScrcpyManager.shared.launchScrcpy(phoneIp: appState.connectedIp) }
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
