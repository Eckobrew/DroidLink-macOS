import SwiftUI

public struct CallsView: View {
    @EnvironmentObject var appState: AppState
    @State private var dialpadNumber: String = ""

    public var body: some View {
        Group {
            if let activeCall = appState.activeCall {
                ActiveCallView(call: activeCall)
            } else {
                HStack(spacing: 0) {
                    // Call History Column
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Recent Calls")
                                .font(.headline)
                                .fontWeight(.semibold)
                            Spacer()
                            if !appState.callHistory.isEmpty {
                                Text("\(appState.callHistory.count)")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()

                        CallHistoryListView(calls: appState.callHistory) { number, name in
                            dialpadNumber = number
                            appState.dialCall(number: number, contactName: name)
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))

                    Divider()

                    // Keypad / Dialer Column
                    VStack(spacing: 20) {
                        // Top Audio Status Pill
                        HStack {
                            if appState.isBluetoothHandsetPaired {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                    Text("Audio Ready • \(appState.pairedDevice?.name ?? "Phone")")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1))
                            } else if appState.pairedDevice != nil {
                                HStack(spacing: 8) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    Text("Bluetooth Audio Disconnected")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Button("Connect") {
                                        appState.initiateBluetoothPairing()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.08))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 16)

                        Spacer()

                        DialerPadView(phoneNumber: $dialpadNumber) { number in
                            appState.dialCall(number: number)
                        } onDigitTapped: { digit in
                            CallAudioManager.shared.playDtmfTone(digit: digit)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
        .onAppear {
            appState.checkBluetoothHandsetStatus()
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            appState.checkBluetoothHandsetStatus()
        }
    }
}
