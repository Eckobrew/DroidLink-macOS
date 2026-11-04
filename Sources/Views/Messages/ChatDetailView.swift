import SwiftUI

public struct ChatDetailView: View {
    let thread: ChatThread
    @EnvironmentObject var appState: AppState
    @State private var inputText: String = ""
    @State private var preferRcs: Bool = true

    private var visibleMessages: [ChatMessage] {
        appState.activeThreadMessages
    }

    private var totalCount: Int {
        appState.activeThreadTotalCount
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Chat Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(thread.contactName)
                            .font(.headline)

                        if thread.isRcs {
                            Label("RCS Chat", systemImage: "sparkles")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        } else {
                            Text("SMS / MMS")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.2))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }

                    Text(thread.contactAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Call Contact Button
                Button {
                    let number = thread.contactAddress.isEmpty ? thread.id : thread.contactAddress
                    appState.dialCall(number: number, contactName: thread.contactName)
                    appState.selectedNavigation = .calls
                } label: {
                    Label("Call", systemImage: "phone.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Message Scroll List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if totalCount > visibleMessages.count {
                            Button("Load Earlier Messages (\(totalCount - visibleMessages.count) more)") {
                                appState.loadEarlierMessages(count: 150)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                        }

                        ForEach(visibleMessages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: visibleMessages.count) { _, _ in
                    if let lastMsg = visibleMessages.last {
                        proxy.scrollTo(lastMsg.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let lastMsg = visibleMessages.last {
                        proxy.scrollTo(lastMsg.id, anchor: .bottom)
                    }
                    appState.markThreadAsRead(threadId: thread.id)
                }
            }

            Divider()

            // Composer Area
            HStack(spacing: 12) {
                // Protocol Selector
                Menu {
                    Button("Prefer RCS") { preferRcs = true }
                    Button("Send as SMS") { preferRcs = false }
                } label: {
                    Text(preferRcs ? "RCS" : "SMS")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(preferRcs ? Color.blue : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 44)

                // Text Input
                TextField(preferRcs ? "RCS Message..." : "Text Message...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onSubmit {
                        sendMessage()
                    }

                // Send Button
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        let targetNumber = (thread.contactAddress.isEmpty || thread.contactAddress == "Me") ? thread.id : thread.contactAddress
        appState.sendMessage(
            to: targetNumber,
            text: text,
            threadId: thread.id,
            isRcs: preferRcs
        )
    }
}
