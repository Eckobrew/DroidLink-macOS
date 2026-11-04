import SwiftUI

public struct NewMessageSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var recipient: String = ""
    @State private var messageText: String = ""
    @State private var preferRcs: Bool = true

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
                TextField("Phone number or contact name", text: $recipient)
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
                Toggle("Send with RCS (Rich Communication Services)", isOn: $preferRcs)
                    .font(.caption)

                Spacer()

                Button("Send") {
                    let cleanedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanedRecipient.isEmpty && !text.isEmpty else { return }

                    let threadId = "thread_\(cleanedRecipient.filter { $0.isNumber })"
                    appState.sendMessage(to: cleanedRecipient, text: text, threadId: threadId, isRcs: preferRcs)
                    appState.selectedThreadId = threadId
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(recipient.isEmpty || messageText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
