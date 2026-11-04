import SwiftUI

public struct IncomingCallNotificationView: View {
    let call: PhoneCall
    @EnvironmentObject var appState: AppState

    public var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 48, height: 48)
                Image(systemName: "phone.arrow.down.left.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(call.contactName.isEmpty ? "Incoming Call" : call.contactName)
                    .font(.headline)
                    .lineLimit(1)
                Text(call.phoneNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Bluetooth Handset Available")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            Spacer()

            // Decline Button
            Button {
                appState.declineIncomingCall()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 40, height: 40)
                    Image(systemName: "phone.down.fill")
                        .font(.body)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            // Answer Button
            Button {
                appState.answerIncomingCall()
                appState.selectedNavigation = .calls
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 40, height: 40)
                    Image(systemName: "phone.fill")
                        .font(.body)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}
