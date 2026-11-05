import SwiftUI

/// Primary click opens the last-used mode; the disclosure menu selects the next mode.
struct DesktopModeButton: View {
    @ObservedObject private var manager = NativeMirrorManager.shared
    var body: some View {
        Menu {
            Button { manager.startDesktop(mode: .windowed1080p) } label: {
                Label("Windowed — 1080p", systemImage: manager.desktopMode == .windowed1080p ? "checkmark" : "macwindow")
            }
            Button { manager.startDesktop(mode: .fullScreen) } label: {
                let configuration = manager.desktopScreenConfiguration
                Label("Full screen — \(configuration.width) × \(configuration.height) · New Space", systemImage: manager.desktopMode == .fullScreen ? "checkmark" : "arrow.up.left.and.arrow.down.right")
            }
        } label: {
            Label("Desktop", systemImage: "desktopcomputer").labelStyle(.titleAndIcon)
        } primaryAction: {
            manager.startDesktop()
        }
        .help("Android desktop via ADB. Click to open the last mode or choose windowed 1080p/full screen in a new Space.")
        .fixedSize()
    }
}
