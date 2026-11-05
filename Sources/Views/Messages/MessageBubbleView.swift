import SwiftUI

public struct MessageBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject private var appState: AppState

    private var bubbleBackground: Color {
        if message.isFromMe {
            if message.messageType == .unknown { return Color.gray }
            return message.messageType == .rcs ? Color.blue : Color.green.opacity(0.85)
        } else {
            return Color(NSColor.controlBackgroundColor)
        }
    }

    public var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
                ForEach(message.attachments, id: \.url) { attachment in
                    MessageImageView(attachment: attachment)
                }
                if message.attachments.isEmpty, let url = message.attachmentUrl {
                    MessageImageView(attachment: MessageAttachment(url: url, mimeType: message.attachmentMimeType ?? "image/jpeg"))
                }
                // Main Bubble
                if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(message.isFromMe ? Color.clear : Color.secondary.opacity(0.15), lineWidth: 1)
                    )

                }

                // Sub-caption: Timestamp, Protocol badge, Status
                HStack(spacing: 4) {
                    if message.isFromMe {
                        statusIcon(for: message.status)
                        Text(message.status == .onPhone ? "Finish sending on phone" : (message.status == .sent && message.messageType == .unknown ? "Sent to messaging app" : message.status.rawValue.capitalized))
                            .font(.caption2)
                            .foregroundStyle(message.status == .failed ? .red : .secondary)
                    }

                    Text(timeString(from: message.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.messageType != .unknown {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(message.messageType.rawValue)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(message.messageType == .rcs ? .blue : .secondary)
                    }
                }
                .padding(.horizontal, 4)

                if message.isFromMe && message.status == .failed && message.attachments.isEmpty {
                    Button("Retry as SMS") { appState.retryMessageAsSms(message) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(for status: MessageDeliveryStatus) -> some View {
        switch status {
        case .onPhone:
            Image(systemName: "iphone.and.arrow.forward").font(.caption2)
        case .sending:
            ProgressView()
                .controlSize(.mini)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        case .delivered:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
        case .read:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
