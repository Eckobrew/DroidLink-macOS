import SwiftUI

public struct ActiveCallView: View {
    let call: PhoneCall
    @EnvironmentObject var appState: AppState
    @State private var showKeypad: Bool = false
    @State private var dummyNumber: String = ""

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Avatar & Contact Info
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 90, height: 90)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Color.accentColor)
                }

                Text(call.contactName.isEmpty ? call.phoneNumber : call.contactName)
                    .font(.system(size: 24, weight: .bold))

                if !call.contactName.isEmpty && call.contactName != call.phoneNumber {
                    Text(call.phoneNumber)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Call State & Duration
                if call.state == .active {
                    Text(formatDuration(call.duration))
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                } else {
                    Text(call.state.rawValue.capitalized + "...")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Bluetooth Handset Indicator
                HStack(spacing: 6) {
                    Image(systemName: "headphones")
                        .font(.caption)
                    Text("Handset Mode: Bluetooth Audio")
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.12))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
            }

            // In-Call DTMF Keypad Drawer (Collapsible)
            if showKeypad {
                VStack(spacing: 8) {
                    Text("Touch Tones (DTMF)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DialerPadView(
                        phoneNumber: $dummyNumber,
                        onCall: { _ in },
                        onDigitTapped: { digit in
                            appState.sendDtmf(digit: digit)
                        }
                    )
                    .scaleEffect(0.85)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            // Call Action Buttons
            HStack(spacing: 32) {
                // Mute Button
                Button {
                    appState.toggleMute()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(call.isMuted ? Color.orange : Color(NSColor.controlBackgroundColor))
                                .frame(width: 56, height: 56)
                            Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.title3)
                                .foregroundStyle(call.isMuted ? Color.white : Color.primary)
                        }
                        Text(call.isMuted ? "Unmute" : "Mute")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)

                // Keypad Toggle
                Button {
                    withAnimation(.spring()) {
                        showKeypad.toggle()
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(showKeypad ? Color.blue : Color(NSColor.controlBackgroundColor))
                                .frame(width: 56, height: 56)
                            Image(systemName: "circle.grid.3x3.fill")
                                .font(.title3)
                                .foregroundStyle(showKeypad ? Color.white : Color.primary)
                        }
                        Text("Keypad")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)

                // Audio Device Menu
                Menu {
                    Button("Bluetooth Hands-Free (Android)") { }
                    Button("MacBook Speakers & Microphone") { }
                    Divider()
                    Button("Audio Settings...") {
                        appState.selectedNavigation = .settings
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color(NSColor.controlBackgroundColor))
                                .frame(width: 56, height: 56)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.title3)
                                .foregroundStyle(Color.primary)
                        }
                        Text("Audio")
                            .font(.caption)
                    }
                }
                .menuStyle(.borderlessButton)

                // End Call Button
                Button {
                    appState.hangupCall()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 56, height: 56)
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        Text("End")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
