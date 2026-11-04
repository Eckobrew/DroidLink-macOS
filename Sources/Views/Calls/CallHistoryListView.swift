import SwiftUI

public struct CallHistoryListView: View {
    let calls: [PhoneCall]
    var onRedial: (String, String) -> Void

    public var body: some View {
        List {
            if calls.isEmpty {
                Text("No recent calls")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(calls) { call in
                    HStack(spacing: 12) {
                        callIcon(for: call)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.contactName.isEmpty ? call.phoneNumber : call.contactName)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(call.state == .missed ? Color.red : Color.primary)

                            HStack(spacing: 4) {
                                Text(call.phoneNumber)
                                if call.duration > 0 {
                                    Text("• \(formatDuration(call.duration))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let start = call.startTime {
                            Text(timeString(from: start))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            onRedial(call.phoneNumber, call.contactName)
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func callIcon(for call: PhoneCall) -> some View {
        switch (call.direction, call.state) {
        case (.incoming, .missed):
            Image(systemName: "phone.arrow.down.left.fill")
                .foregroundStyle(.red)
        case (.incoming, .rejected):
            Image(systemName: "phone.down.circle.fill")
                .foregroundStyle(.red)
        case (.incoming, _):
            Image(systemName: "phone.arrow.down.left.fill")
                .foregroundStyle(.green)
        case (.outgoing, _):
            Image(systemName: "phone.arrow.up.right.fill")
                .foregroundStyle(.blue)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func timeString(from date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}
