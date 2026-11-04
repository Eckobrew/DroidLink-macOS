import SwiftUI

public struct MessagesSplitView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var showNewMessageSheet: Bool = false
    @State private var filterRcsOnly: Bool = false

    private var filteredThreads: [ChatThread] {
        if searchText.isEmpty && !filterRcsOnly {
            return appState.threads
        }
        return appState.threads.filter { thread in
            if filterRcsOnly && !thread.isRcs { return false }
            if searchText.isEmpty { return true }
            return thread.contactName.localizedCaseInsensitiveContains(searchText) ||
                   thread.lastMessage.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search & Filter Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search conversations...", text: $searchText)
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

                    // RCS Filter Toggle
                    Button {
                        filterRcsOnly.toggle()
                    } label: {
                        Text("RCS")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(filterRcsOnly ? Color.blue : Color.secondary.opacity(0.15))
                            .foregroundStyle(filterRcsOnly ? Color.white : Color.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show only RCS threads")
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Threads List
                if filteredThreads.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No Messages")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(appState.pairedDevice == nil ? "Pair your phone to view messages" : "Messages from your phone will appear here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $appState.selectedThreadId) {
                        ForEach(filteredThreads) { thread in
                            ThreadRowView(
                                thread: thread,
                                isSelected: appState.selectedThreadId == thread.id
                            )
                            .tag(thread.id)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewMessageSheet = true
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                }
            }
        } detail: {
            if let thread = appState.selectedThread {
                ChatDetailView(thread: thread)
            } else {
                emptyPlaceholderView
            }
        }
        .sheet(isPresented: $showNewMessageSheet) {
            NewMessageSheet()
        }
    }

    private var emptyPlaceholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a conversation")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Or start a new RCS / SMS message")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
