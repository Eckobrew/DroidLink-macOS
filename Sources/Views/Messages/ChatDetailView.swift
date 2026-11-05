import SwiftUI
import UniformTypeIdentifiers

public struct ChatDetailView: View {
    let thread: ChatThread
    @EnvironmentObject var appState: AppState
    @State private var inputText: String = ""
    @State private var preferRcs: Bool = true
    @State private var imageData: Data?
    @State private var choosingImage = false
    @State private var preparingImage = false
    private var canUseMessagingApp: Bool { appState.canUseMessagingApp(threadId: thread.id) }
    private var canSend: Bool { !preparingImage && (imageData != nil || (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!thread.id.hasPrefix("notification_group_") || canUseMessagingApp))) }

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
                .onChange(of: visibleMessages.last?.id) { _, _ in
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

            if let imageData, let image = NSImage(data: imageData) {
                HStack {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 80)
                    Text("Finish sending this image on your phone.").font(.caption)
                    Button("Remove") { self.imageData = nil }
                    Spacer()
                }.padding(8)
            }
            // Composer Area
            HStack(spacing: 12) {
                Button { choosingImage = true } label: { Image(systemName: "photo.badge.plus") }
                    .help("Choose an image to send using the phone composer")
                    .disabled(preparingImage)
                // Protocol Selector
                if canUseMessagingApp && imageData == nil {
                Menu {
                    Button("Use messaging app (RCS / SMS)") { preferRcs = true }
                    Button("Send as SMS") { preferRcs = false }
                } label: {
                    Text(preferRcs ? "Auto" : "SMS")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(preferRcs ? Color.blue : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 44)
                } else { Text(imageData != nil ? "Image" : (thread.id.hasPrefix("notification_group_") ? "Unavailable" : "SMS")).font(.caption).foregroundStyle(.secondary) }

                // Text Input
                TextField(preferRcs ? "Message..." : "SMS Message...", text: $inputText)
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
                        .foregroundStyle(!canSend ? Color.secondary : Color.blue)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .task(id: thread.id) {
            inputText = ""
            imageData = nil
            while !Task.isCancelled {
                appState.refreshMessageCapabilities(threadId: thread.id, recipient: thread.contactAddress.isEmpty ? thread.id : thread.contactAddress)
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let selectedThread = thread.id
            preparingImage = true
            Task {
                do {
                    let data = try await Task.detached { try MessageImageEncoder.jpeg(from: url) }.value
                    if selectedThread == appState.selectedThreadId { imageData = data }
                } catch { appState.messageError = "Unable to open this image. Choose another image under 3 MB after resizing." }
                preparingImage = false
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let image = imageData
        imageData = nil
        inputText = ""

        let targetNumber = (thread.contactAddress.isEmpty || thread.contactAddress == "Me") ? thread.id : thread.contactAddress
        appState.sendMessage(
            to: targetNumber,
            text: text,
            threadId: thread.id,
            isRcs: preferRcs && canUseMessagingApp,
            imageData: image
        )
    }
}
