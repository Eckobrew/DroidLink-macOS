import SwiftUI

public struct ContactsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""
    @State private var selectedContactId: String?

    private var filteredContacts: [ContactItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return appState.contacts
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return appState.contacts.filter { contact in
            contact.name.lowercased().contains(query) ||
            contact.phoneNumbers.contains { $0.contains(query) }
        }
    }

    private var selectedContact: ContactItem? {
        guard let id = selectedContactId else { return filteredContacts.first }
        return appState.contacts.first { $0.id == id }
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search contacts...", text: $searchText)
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
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                if filteredContacts.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(appState.contacts.isEmpty ? "No Contacts Synced" : "No Matching Contacts")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(appState.contacts.isEmpty ? "Contacts from your Android phone will automatically sync here over Wi-Fi." : "Try a different search term.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredContacts, selection: $selectedContactId) { contact in
                        ContactRowView(contact: contact)
                            .tag(contact.id)
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            if let contact = selectedContact {
                ContactDetailCardView(contact: contact)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.2")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Select a contact to view details")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear {
            if selectedContactId == nil {
                selectedContactId = filteredContacts.first?.id
            }
        }
    }
}

// MARK: - Contact Row View
private struct ContactRowView: View {
    let contact: ContactItem

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(avatarColor(for: contact.name))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(initials(for: contact.name))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let firstNum = contact.phoneNumbers.first {
                    Text(firstNum)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func initials(for name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if parts.count >= 2, let first = parts.first?.first, let second = parts[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .indigo, .pink, .green]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}

// MARK: - Contact Detail Card View
private struct ContactDetailCardView: View {
    let contact: ContactItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header Profile
                VStack(spacing: 12) {
                    Circle()
                        .fill(avatarColor(for: contact.name))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Text(initials(for: contact.name))
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

                    Text(contact.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    // Quick Action Pills
                    if let primaryNumber = contact.phoneNumbers.first {
                        HStack(spacing: 16) {
                            Button {
                                appState.dialCall(number: primaryNumber, contactName: contact.name)
                                appState.selectedNavigation = .calls
                            } label: {
                                Label("Call", systemImage: "phone.fill")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            Button {
                                openConversation(with: primaryNumber, name: contact.name)
                            } label: {
                                Label("Message", systemImage: "message.fill")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                }
                .padding(.top, 32)

                Divider()
                    .padding(.horizontal, 32)

                // Phone Numbers Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Phone Numbers")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)

                    ForEach(contact.phoneNumbers, id: \.self) { number in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Phone")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(number)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Button {
                                openConversation(with: number, name: contact.name)
                            } label: {
                                Image(systemName: "message.fill")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.borderless)
                            .help("Message \(number)")

                            Button {
                                appState.dialCall(number: number, contactName: contact.name)
                                appState.selectedNavigation = .calls
                            } label: {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                            .help("Call \(number)")
                        }
                        .padding(14)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 32)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func openConversation(with number: String, name: String) {
        // Check if an existing thread exists matching this number
        let clean = number.filter { $0.isNumber || $0 == "+" }
        let suffix7 = String(clean.suffix(7))
        if let existing = appState.threads.first(where: {
            $0.id == clean || $0.contactAddress == clean || (!suffix7.isEmpty && $0.id.contains(suffix7))
        }) {
            appState.selectedThreadId = existing.id
        } else {
            // Create a placeholder thread
            let newThread = ChatThread(
                id: clean,
                contactName: name,
                contactAddress: clean,
                lastMessage: "Start conversation",
                lastMessageDate: Date(),
                unreadCount: 0,
                isRcs: true
            )
            appState.threads.insert(newThread, at: 0)
            appState.selectedThreadId = clean
        }
        appState.selectedNavigation = .messages
    }

    private func initials(for name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if parts.count >= 2, let first = parts.first?.first, let second = parts[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .indigo, .pink, .green]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}
