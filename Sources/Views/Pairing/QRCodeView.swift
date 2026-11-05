import SwiftUI
import CoreImage.CIFilterBuiltins

public struct QRCodeView: View {
    @EnvironmentObject var appState: AppState
    @State private var qrImage: NSImage?
    @State private var localIps: [String] = []

    private let filter = CIFilter.qrCodeGenerator()
    private let context = CIContext()

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerView
                qrCardView
                Text("Connect both devices to the same Wi-Fi network to pair. Bluetooth keeps them connected afterward when available.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 450)
                pairedDeviceView
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            localIps = WiFiTransport.getLocalIPAddresses()
            generateQRCode()
        }
    }

    @ViewBuilder
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("Pair Your Android Phone")
                .font(.title)
                .fontWeight(.bold)
            Text("Open the Droid Link companion app on your phone (Android 12+) and scan this QR code to establish an end-to-end encrypted connection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private var qrCardView: some View {
        VStack(spacing: 16) {
            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
            } else {
                ProgressView("Generating secure pairing key...")
                    .frame(width: 240, height: 240)
            }

            Label("End-to-end encrypted", systemImage: "lock.shield.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var pairedDeviceView: some View {
        if let paired = appState.pairedDevice {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(appState.activeTransport == .none ? Color.orange : Color.green)
                                .frame(width: 10, height: 10)
                            Text(paired.name)
                                .font(.headline)
                        }
                        Text(appState.activeTransport == .none ? "Paired • Disconnected" : "Connected via \(appState.activeTransport.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        appState.unpairCurrentDevice()
                        generateQRCode()
                    } label: {
                        Label("Unpair Phone", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .frame(maxWidth: 550)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func generateQRCode() {
        let macName = Host.current().localizedName ?? "MacBook"
        let rawHostName = ProcessInfo.processInfo.hostName
        let mDnsHost = rawHostName.hasSuffix(".local") ? rawHostName : "\(rawHostName).local"

        var targetHosts: [String] = []
        if !mDnsHost.isEmpty {
            targetHosts.append(mDnsHost)
        }
        for ip in localIps where !targetHosts.contains(ip) {
            targetHosts.append(ip)
        }

        let payload = PairingPayload(
            deviceId: macName,
            deviceName: macName,
            publicKey: CryptoManager.shared.localPublicKeyBase64,
            wifiPort: 8765,
            wifiIps: targetHosts,
            hostName: mDnsHost,
            bleServiceUuid: BluetoothTransport.serviceUUID.uuidString,
            pairingNonce: UUID().uuidString
        )

        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        filter.message = Data(jsonString.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)

        if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 240, height: 240))
            self.qrImage = nsImage
        }
    }
}
