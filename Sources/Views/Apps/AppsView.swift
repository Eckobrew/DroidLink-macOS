import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct AppsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var filterMode: AppFilterMode = .all
    @State private var isTargetedForDrop: Bool = false
    @State private var installStatusBanner: String? = nil
    @State private var isInstalling: Bool = false
    @State private var launchingPackage: String? = nil

    private enum AppFilterMode: String, CaseIterable, Identifiable {
        case all = "All"
        case user = "User"
        case system = "System"

        var id: String { rawValue }
    }

    private var filteredApps: [InstalledApp] {
        var list = appState.apps
        switch filterMode {
        case .all:
            break
        case .user:
            list = list.filter { !$0.isSystemApp }
        case .system:
            list = list.filter { $0.isSystemApp }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(query) ||
                $0.packageName.lowercased().contains(query)
            }
        }
        return list
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Top Header Toolbar
                HStack(spacing: 12) {
                    // Search Bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search \(appState.apps.count) apps on \(appState.pairedDevice?.name ?? "Phone")...", text: $searchText)
                            .textFieldStyle(.plain)

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Filter Segmented Control
                    Picker("Filter", selection: $filterMode) {
                        ForEach(AppFilterMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    // Mirror Entire Screen Shortcut
                    Button {
                        ScrcpyManager.shared.launchScrcpy(phoneIp: ConnectionManager.shared.connectedIp)
                    } label: {
                        Label("Mirror Screen", systemImage: "iphone")
                    }
                    .buttonStyle(.bordered)
                    .help("Launch wireless screen mirror via embedded scrcpy")

                    // Refresh Button
                    Button {
                        appState.refreshApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh installed apps list from phone")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Status Banner (Installing / Finished)
                if let banner = installStatusBanner {
                    HStack(spacing: 8) {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: banner.contains("successfully") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(banner.contains("successfully") ? .green : .orange)
                        }
                        Text(banner)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            withAnimation { installStatusBanner = nil }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(banner.contains("successfully") ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Drag & Drop Hint Banner
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Tip: Drag and drop any **.apk** file into this window to install it directly on your phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

                Divider()

                // App Grid Content
                if filteredApps.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(appState.apps.isEmpty ? "No Apps Synced Yet" : "No Matching Apps")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(appState.apps.isEmpty ?
                             "Apps installed on your Android device will appear here automatically when connected." :
                             "Try searching with a different app name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if appState.apps.isEmpty && appState.pairedDevice != nil {
                            Button("Sync Apps Now") {
                                appState.refreshApps()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 110, maximum: 130), spacing: 20)],
                            spacing: 24
                        ) {
                            ForEach(filteredApps) { app in
                                AppGridCard(
                                    app: app,
                                    isLaunching: launchingPackage == app.packageName
                                ) {
                                    handleAppClick(app)
                                }
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .background(Color(NSColor.windowBackgroundColor))

            // Drop Overlay when dragging file over window
            if isTargetedForDrop {
                ZStack {
                    Color.blue.opacity(0.18)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                        Text("Drop APK to Install on \(appState.pairedDevice?.name ?? "Phone")")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("The package will be installed automatically via Android Platform Tools.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    )
                }
                .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleAppClick(_ app: InstalledApp) {
        withAnimation {
            launchingPackage = app.packageName
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

        appState.launchApp(app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                if launchingPackage == app.packageName {
                    launchingPackage = nil
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                if let directUrl = item as? URL {
                    DispatchQueue.main.async {
                        self.processApkUrl(directUrl)
                    }
                    return
                }
                return
            }
            DispatchQueue.main.async {
                self.processApkUrl(url)
            }
        }
        return true
    }

    private func processApkUrl(_ url: URL) {
        guard url.pathExtension.lowercased() == "apk" else {
            DispatchQueue.main.async {
                withAnimation {
                    self.installStatusBanner = "File is not an Android APK package (.apk)"
                    self.isInstalling = false
                }
            }
            return
        }

        DispatchQueue.main.async {
            withAnimation {
                self.isInstalling = true
                self.installStatusBanner = "Installing \(url.lastPathComponent) on \(appState.pairedDevice?.name ?? "Phone")..."
            }
        }

        appState.installApk(from: url) { success, message in
            DispatchQueue.main.async {
                withAnimation {
                    self.isInstalling = false
                    self.installStatusBanner = message
                }
                if success {
                    appState.refreshApps()
                }
            }
        }
    }
}

// MARK: - App Grid Card Component
private struct AppGridCard: View {
    let app: InstalledApp
    let isLaunching: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    private var appIconImage: NSImage? {
        guard let base64 = app.iconBase64,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return NSImage(data: data)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if let nsImg = appIconImage {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 64, height: 64)
                            .overlay(
                                Image(systemName: "app.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
                    }

                    if isLaunching {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 64, height: 64)
                            .overlay(
                                ProgressView()
                                    .colorInvert()
                            )
                    }
                }
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)

                // App Label
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top)

                if app.isSystemApp {
                    Text("SYSTEM")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .frame(width: 110)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            self.isHovered = hovering
        }
        .help("Click to launch \(app.name) and open mirroring window")
    }
}
