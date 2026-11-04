import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var availableAudioDevices: [AudioDeviceItem] = []
    @State private var preferRcsByDefault: Bool = true
    @State private var autoConnectBluetooth: Bool = true
    @State private var showPairingSheet: Bool = false

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Phone Pairing Header Section
                pairingSection

                Form {
                    connectionSection
                    callsSection
                    messagesSection
                    cryptoSection
                    if appState.pairedDevice != nil {
                        dangerZoneSection
                    }
                }
                .formStyle(.grouped)
            }
            .padding(16)
        }
        .onAppear {
            availableAudioDevices = CallAudioManager.shared.getAvailableAudioDevices()
        }
        .sheet(isPresented: $showPairingSheet) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") {
                        showPairingSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .padding()
                }
                QRCodeView()
            }
            .frame(minWidth: 520, minHeight: 620)
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        if let device = appState.pairedDevice {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.title3)
                            .fontWeight(.bold)

                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(appState.activeTransport == .none ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                Text(appState.activeTransport == .none ? "Connecting..." : "Connected via \(appState.activeTransport.rawValue)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }

                            if let ip = ConnectionManager.shared.connectedIp {
                                Text("• \(ip)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button {
                        showPairingSheet = true
                    } label: {
                        Label("Pair New Phone", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        } else {
            // No phone paired: display pairing view right here inside settings
            VStack(spacing: 16) {
                QRCodeView()
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection & Transport") {
            LabeledContent("Active Transport") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.activeTransport == .none ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    Text(appState.activeTransport.rawValue)
                        .fontWeight(.medium)
                }
            }

            LabeledContent("Wi-Fi Listener Port") {
                Text("8765 (mDNS / Bonjour _droiddock._tcp)")
                    .foregroundStyle(.secondary)
            }

            Toggle("Auto-fallback to Bluetooth LE when Wi-Fi drops", isOn: $autoConnectBluetooth)
        }
    }

    @ViewBuilder
    private var callsSection: some View {
        Section("Phone Calls & Handset Audio") {
            LabeledContent("Handset Routing") {
                Text("Bluetooth Audio Gateway (HFP)")
                    .foregroundStyle(.secondary)
            }

            if availableAudioDevices.isEmpty {
                Text("No external audio devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Active Call Audio Device", selection: .constant(availableAudioDevices.first?.id ?? 0)) {
                    ForEach(availableAudioDevices) { dev in
                        Text("\(dev.name)\(dev.isBluetooth ? " (Bluetooth)" : "")").tag(dev.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        Section("Messages & RCS") {
            Toggle("Prefer RCS over SMS whenever recipient is RCS-capable", isOn: $preferRcsByDefault)
            LabeledContent("RCS Carrier Bridge") {
                Text("Active via Google Messages Companion Engine")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cryptoSection: some View {
        Section("End-to-End Cryptography") {
            LabeledContent("Key Agreement") {
                Text("ECDH P-256 (secp256r1)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Symmetric Cipher") {
                Text("AES-256-GCM (128-bit Auth Tag)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Verification Fingerprint") {
                Text(CryptoManager.shared.verificationFingerprint)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
            }
            LabeledContent("Local Public Key") {
                let keyPrefix = String(CryptoManager.shared.localPublicKeyBase64.prefix(20))
                Text("\(keyPrefix)...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var dangerZoneSection: some View {
        Section("Paired Device Management") {
            Button(role: .destructive) {
                appState.unpairCurrentDevice()
            } label: {
                Label("Unpair Current Phone", systemImage: "link.badge.plus")
            }
        }
    }
}
