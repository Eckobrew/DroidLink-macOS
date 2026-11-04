import SwiftUI

public struct ThreadRowView: View {
    let thread: ChatThread
    let isSelected: Bool

    private var badgeBgColor: Color {
        thread.isRcs ? Color.blue.opacity(0.18) : Color.gray.opacity(0.2)
    }

    private var badgeFgColor: Color {
        thread.isRcs ? Color.blue : Color.secondary
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Avatar Circle
            ZStack {
                Circle()
                    .fill(avatarColor(for: thread.contactName))
                    .frame(width: 44, height: 44)
                Text(initials(for: thread.contactName))
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.contactName)
                        .font(.body)
                        .fontWeight(thread.unreadCount > 0 ? .bold : .medium)
                        .lineLimit(1)

                    Spacer()

                    Text(timeString(from: thread.lastMessageDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text(thread.lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(thread.unreadCount > 0 ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer()

                    // RCS / SMS Badge
                    Text(thread.isRcs ? "RCS" : "SMS")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badgeBgColor)
                        .foregroundStyle(badgeFgColor)
                        .clipShape(Capsule())

                    // Unread Count Badge
                    if thread.unreadCount > 0 {
                        Text("\(thread.unreadCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2, let first = parts.first?.first, let second = parts.last?.first {
            return "\(first)\(second)".uppercased()
        } else if let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .indigo, .teal, .orange, .pink]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }

    private func timeString(from date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}
