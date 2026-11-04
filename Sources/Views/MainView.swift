import SwiftUI

public struct MainView: View {
    @EnvironmentObject var appState: AppState

    public var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                NotificationsSidebarView()
                    .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
            } detail: {
                Group {
                    switch appState.selectedNavigation {
                    case .messages:
                        MessagesSplitView()
                    case .calls:
                        CallsView()
                    case .contacts:
                        ContactsView()
                    case .apps:
                        AppsView()
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup(placement: .principal) {
                        HStack(spacing: 2) {
                            ForEach(AppNavigationItem.allCases) { item in
                                TopNavigationTabButton(
                                    item: item,
                                    isSelected: appState.selectedNavigation == item,
                                    unreadCount: item == .messages ? appState.totalUnreadMessages : 0,
                                    hasActiveCall: item == .calls && appState.activeCall != nil
                                ) {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        appState.selectedNavigation = item
                                    }
                                }
                            }
                        }
                        .padding(2)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            ScrcpyManager.shared.launchScrcpy(phoneIp: appState.connectedIp)
                        }) {
                            Label("Mirror Screen", systemImage: "display")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .help("Launch screen copy mirroring with scrcpy")
                    }
                }
            }

            // Top Floating Incoming Call Banner
            if let incoming = appState.incomingCall {
                IncomingCallNotificationView(call: incoming)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .onAppear {
            appState.requestNotificationPermissionsIfNeeded()
        }
    }
}

private struct TopNavigationTabButton: View {
    let item: AppNavigationItem
    let isSelected: Bool
    let unreadCount: Int
    let hasActiveCall: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.iconName)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                Text(item.rawValue)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .clipShape(Capsule())
                } else if hasActiveCall {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(isSelected ? Color(NSColor.controlAccentColor).opacity(0.2) : Color.clear)
            .foregroundStyle(isSelected ? Color(NSColor.controlAccentColor) : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
