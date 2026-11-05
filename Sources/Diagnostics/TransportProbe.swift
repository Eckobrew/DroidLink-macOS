import Foundation
import Darwin

/// Opt-in, side-effect-free payload probe. It never sends chat/call actions.
/// Run the packaged app with DROIDLINK_TRANSPORT_PROBE=1 and an attached,
/// already-paired companion. Only DroidDock's TCP listener is paused.
@MainActor
final class TransportProbe: ConnectionManagerDelegate {
    private let manager = ConnectionManager()
    private var transport: ActiveTransport = .none
    private var echoes = Set<String>()
    private var bleEnvelopeCount = 0
    private var transitions: [String] = []

    nonisolated func connectionManager(didReceiveEnvelope envelope: MessageEnvelope) {
        Task { @MainActor in
            if self.transport == .bluetooth { self.bleEnvelopeCount += 1 }
            if envelope.type == .transportProbe { self.echoes.insert(envelope.payload) }
        }
    }
    nonisolated func connectionManager(didUpdateTransport transport: ActiveTransport) {
        Task { @MainActor in
            self.transport = transport
            self.transitions.append(transport.rawValue)
            print("[TransportProbe] Active transport: \(transport.rawValue)")
        }
    }
    nonisolated func connectionManager(didCompletePairing device: PairedDevice) {}

    private func wait(_ seconds: Double, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func run() async {
        var result: [String: Any] = [:]
        let previous = manager.bluetoothFallbackEnabled
        manager.delegate = self
        manager.setBluetoothFallbackEnabled(true)
        guard manager.currentPairedDevice != nil else {
            await finish(["success": false, "error": "Pair the phone over Wi-Fi before running this probe"], previous: previous)
            return
        }
        manager.startServices()
        let initialWiFi = await wait(60) { self.transport == .wifi }
        result["initialWiFi"] = initialWiFi
        guard initialWiFi else { await finish(result.merging(["success": false, "error": "Wi-Fi session did not verify"]) { _, b in b }, previous: previous); return }
        let warmBLE = await wait(75) { await self.manager.verifiedBluetoothReady() }
        result["verifiedBLEStandby"] = warmBLE
        guard warmBLE else { await finish(result.merging(["success": false, "error": "BLE session did not verify"]) { _, b in b }, previous: previous); return }

        print("[TransportProbe] Pausing DroidDock TCP listener; computer Wi-Fi stays enabled")
        manager.wifiTransport.stop()
        let fallback = await wait(30) { self.transport == .bluetooth }
        result["fallbackToBLE"] = fallback
        guard fallback else { await finish(result.merging(["success": false, "error": "No Bluetooth failover"]) { _, b in b }, previous: previous); return }
        let payload = "ble-probe:" + Data((0..<262_144).map { UInt8($0 % 251) }).base64EncodedString()
        manager.sendEnvelope(MessageEnvelope(type: .transportProbe, payload: payload))
        let echoed = await wait(150) { self.echoes.contains(payload) }
        result["largeBLEEcho"] = echoed
        result["probeBytes"] = payload.utf8.count
        result["BLEEnvelopesReceived"] = bleEnvelopeCount

        print("[TransportProbe] Restoring DroidDock TCP listener")
        do { try manager.wifiTransport.startListening() }
        catch { result["listenerError"] = error.localizedDescription }
        let recovered = await wait(60) { self.transport == .wifi }
        result["recoveredWiFi"] = recovered
        let recoveryPayload = "wifi-recovery:" + UUID().uuidString
        manager.sendEnvelope(MessageEnvelope(type: .transportProbe, payload: recoveryPayload))
        let recoveryEcho = await wait(15) { self.echoes.contains(recoveryPayload) }
        result["recoveryEcho"] = recoveryEcho
        result["transitions"] = transitions
        result["success"] = initialWiFi && warmBLE && fallback && echoed && recovered && recoveryEcho
        await finish(result, previous: previous)
    }

    private func finish(_ result: [String: Any], previous: Bool) async {
        if let path = ProcessInfo.processInfo.environment["DROIDLINK_PROBE_REPORT"],
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("[TransportProbe] Result: \(result["success"] as? Bool == true ? "PASS" : "FAIL")")
        manager.setBluetoothFallbackEnabled(previous)
        manager.stopServices()
        try? await Task.sleep(for: .milliseconds(500))
        exit(result["success"] as? Bool == true ? 0 : 1)
    }
}
