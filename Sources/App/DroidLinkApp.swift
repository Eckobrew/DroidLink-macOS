import SwiftUI

@main
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
