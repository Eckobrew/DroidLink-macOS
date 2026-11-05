import SwiftUI
import UniformTypeIdentifiers

public struct NewMessageSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var recipient: String = ""
    @State private var messageText: String = ""
    @State private var preferRcs: Bool = true
    @State private var imageData: Data?
    @State private var choosingImage = false
    @State private var preparingImage = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Message")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("To:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Phone number", text: $recipient)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $messageText)
                    .font(.body)
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            HStack {
                Button("Add image…") { choosingImage = true }.disabled(preparingImage)
                if imageData != nil {
                    Text("Image attached • Finish on phone").font(.caption)
                    Button("Remove") { imageData = nil }
                }
            }

            HStack {
                if imageData == nil && appState.canUseMessagingApp(threadId: recipient.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Toggle("Prefer messaging app (RCS / SMS)", isOn: $preferRcs).font(.caption)
                } else { Text(imageData == nil ? "SMS" : "Phone composer").font(.caption).foregroundStyle(.secondary) }

                Spacer()

                Button("Send") {
                    let cleanedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanedRecipient.isEmpty && (!text.isEmpty || imageData != nil) else { return }

                    let threadId = cleanedRecipient
                    appState.sendMessage(to: cleanedRecipient, text: text, threadId: threadId, isRcs: preferRcs, imageData: imageData)
                    appState.selectedThreadId = threadId
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preparingImage || recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageData == nil))
            }
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            preparingImage = true
            Task {
                do { imageData = try await Task.detached { try MessageImageEncoder.jpeg(from: url) }.value }
                catch { appState.messageError = "This image could not be opened." }
                preparingImage = false
            }
        }
        .task(id: recipient) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let number = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            if !number.isEmpty { appState.refreshMessageCapabilities(threadId: number, recipient: number) }
        }
        .padding(20)
        .frame(width: 440)
    }
}
