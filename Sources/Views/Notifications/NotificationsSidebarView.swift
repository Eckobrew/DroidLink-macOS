import SwiftUI
import AppKit

public struct NotificationsSidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""

    public init() {}

    private var filteredNotifications: [AppNotification] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return appState.notifications
        }
        let query = searchText.lowercased()
        return appState.notifications.filter {
            $0.appName.lowercased().contains(query) ||
            $0.title.lowercased().contains(query) ||
            $0.text.lowercased().contains(query) ||
            ($0.subText?.lowercased().contains(query) ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)

                Text("Notifications")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .layoutPriority(1)

                if appState.unreadNotificationCount > 0 {
                    Text("\(appState.unreadNotificationCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }

                Spacer()

                if !appState.notifications.isEmpty {
                    Button(action: {
                        withAnimation {
                            appState.clearAllNotifications()
                        }
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear all notifications")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter notifications...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Notifications List or Empty State
            if filteredNotifications.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: searchText.isEmpty ? "bell.slash" : "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No Notifications" : "No matches found")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "Alerts from your phone will sync here in real-time." : "Try a different search query.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredNotifications) { item in
                            NotificationCardView(notification: item)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }

            // Media Controls Panel (only shown when media is controllable or audio handoff is active)
            if appState.isAudioHandoffActive || appState.activeMediaNotification != nil {
                Divider()
                MediaControlsSidebarSection()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider()

            // Clean Status Footer
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.activeTransport == .none ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.pairedDevice?.name ?? "No Phone Paired")
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(appState.activeTransport == .none ? "Disconnected" : "Connected via \(appState.activeTransport.rawValue)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let status = appState.deviceStatus {
                    HStack(spacing: 4) {
                        Image(systemName: status.isCharging ? "battery.100.bolt" : "battery.75")
                            .font(.caption)
                            .foregroundStyle(status.isCharging ? .green : .secondary)
                        Text("\(status.batteryLevel)%")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }

                Button(action: {
                    appState.refreshNotifications()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Refresh notifications from phone")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

private struct MediaControlsSidebarSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            // Header Bar with App/Status
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(appState.isAudioHandoffActive ? Color.accentColor : Color.secondary)

                    Text(appState.activeMediaNotification?.appName.uppercased() ?? "PHONE MEDIA")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                }

                Spacer()

                if appState.isAudioHandoffActive {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 8))
                        Text("Mac Audio")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            // Track & Artist Info with Album Artwork
            HStack(spacing: 9) {
                if let base64 = appState.activeMediaNotification?.iconBase64,
                   let data = Data(base64Encoded: base64),
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(appState.isAudioHandoffActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                            .frame(width: 38, height: 38)

                        Image(systemName: appState.isAudioHandoffActive ? "speaker.wave.3.fill" : "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(appState.isAudioHandoffActive ? Color.accentColor : Color.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.activeMediaNotification?.title ?? (appState.pairedDevice?.name ?? "Phone Audio"))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)

                    Text(appState.activeMediaNotification?.text ?? (appState.activeTransport == .none ? "Phone disconnected" : "Ready to play"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let sub = appState.activeMediaNotification?.subText, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            // Playback Controls Row (Previous, Play/Pause, Next)
            HStack(spacing: 14) {
                Spacer()

                Button(action: {
                    appState.sendMediaCommand("previous")
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Previous Track")

                Button(action: {
                    appState.sendMediaCommand("play_pause")
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(NSColor.controlAccentColor))
                            .frame(width: 28, height: 28)
                        Image(systemName: "playpause.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help("Play / Pause")

                Button(action: {
                    appState.sendMediaCommand("next")
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Next Track")

                Spacer()
            }
            .padding(.vertical, 1)
            .disabled(appState.activeMediaNotification == nil || appState.activeTransport == .none)

            // Audio Handoff Button
            Button(action: {
                appState.toggleAudioHandoff()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.isAudioHandoffActive ? "speaker.wave.3.fill" : "airplayaudio")
                        .font(.system(size: 11, weight: .semibold))

                    Text(appState.isAudioHandoffActive ? "Phone audio on Mac • Mute" : "Listen to Phone Audio")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    appState.isAudioHandoffActive
                        ? Color(NSColor.controlAccentColor).opacity(0.2)
                        : Color.primary.opacity(0.06)
                )
                .foregroundStyle(
                    appState.isAudioHandoffActive
                        ? Color(NSColor.controlAccentColor)
                        : Color.primary
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            appState.isAudioHandoffActive
                                ? Color(NSColor.controlAccentColor).opacity(0.5)
                                : Color.primary.opacity(0.12),
                            lineWidth: 0.8
                        )
                )
            }
            .buttonStyle(.plain)
            .help(appState.isAudioHandoffActive ? "Mute phone audio on this Mac" : "Share supported app audio after approving screen sharing on your phone")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
    }
}

private struct NotificationCardView: View {
    @EnvironmentObject var appState: AppState
    let notification: AppNotification
    @State private var isHovering = false

    private var appIcon: NSImage? {
        if let base64 = notification.iconBase64,
           let data = Data(base64Encoded: base64),
           let img = NSImage(data: data) {
            return img
        }
        if let app = appState.apps.first(where: { $0.packageName == notification.packageName }),
           let base64 = app.iconBase64,
           let data = Data(base64Encoded: base64),
           let img = NSImage(data: data) {
            return img
        }
        return nil
    }

    private var relativeTimeString: String {
        let now = Date()
        let interval = now.timeIntervalSince(notification.date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hrs = Int(interval / 3600)
            return "\(hrs)h ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: notification.date)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header: App Icon, Name, Relative Time, Dismiss (X)
            HStack(spacing: 6) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                } else {
                    Image(systemName: "app.badge.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }

                Text(notification.appName.isEmpty ? notification.packageName : notification.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(relativeTimeString)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button(action: {
                    withAnimation {
                        appState.dismissNotification(notification)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isHovering ? Color.primary : Color.secondary.opacity(0.5))
                        .padding(3)
                        .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss notification")
            }

            // Title
            if !notification.title.isEmpty && notification.title != notification.appName {
                Text(notification.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            // Body
            if !notification.text.isEmpty {
                Text(notification.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Actions footer
            HStack {
                if let sub = notification.subText, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: {
                    appState.launchNotificationApp(notification)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 9))
                        Text("Open App")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(isHovering ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.1))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open app on phone and launch screen copy")
            }
            .padding(.top, 2)
        }
        .padding(9)
        .background(Color(NSColor.controlBackgroundColor).opacity(isHovering ? 0.85 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 0.8)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
