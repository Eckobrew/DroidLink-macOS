import AppKit
import SwiftUI
import CryptoKit

@MainActor
final class NativeMirrorManager: ObservableObject {
    static let shared = NativeMirrorManager()
    @Published var status = "Ready to mirror"
    @Published var isActive = false
    @Published var isStreaming = false
    @Published var controlEnabled = false
    @Published var audioActive = false
    @Published var muted = false
    @Published var includeAudio = false
    @Published var quality = MirrorQuality.balanced
    @Published var frameSize = CGSize(width: 720, height: 1280)
    @Published var fps = 0
    @Published var resumeAvailable = false
    @Published var keepAwake = true
    @Published var dimmed = false
    enum DesktopMode: String { case windowed1080p, fullScreen }
    @Published var desktopMode = DesktopMode(rawValue: UserDefaults.standard.string(forKey: "desktopDisplayMode") ?? "") ?? .windowed1080p
    private(set) var sessionId: String?
    let presenter = MirrorFramePresenter()
    private var channel: MirrorChannel?
    private var playback: MirrorPlayback?
    private var window: MirrorWindowController?
    private weak var mainWindow: NSWindow?
    private var previousSessionId: String?
    private var previousStoppedAt = Date.distantPast
    private var frames = 0
    private var lastFPS = Date()
    private var timeout: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var mainScreenObserver: NSObjectProtocol?
    private init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
    }

    enum MirrorQuality: String, CaseIterable, Identifiable {
        case responsive = "Responsive", balanced = "Balanced", detailed = "Detailed"
        var id: String { rawValue }
        var size: Int { switch self { case .responsive: 960; case .balanced: 1280; case .detailed: 1920 } }
        var bitrate: Int { switch self { case .responsive: 2_000_000; case .balanced: 4_000_000; case .detailed: 8_000_000 } }
    }
    func attachMainWindow(_ window: NSWindow) {
        mainWindow = window
        if let mainScreenObserver { NotificationCenter.default.removeObserver(mainScreenObserver) }
        mainScreenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        if self.window?.window?.isVisible == true { self.window?.attach(to: window) }
    }
    func show() {
        if window == nil { window = MirrorWindowController(manager: self) }
        let opening = window?.window?.isVisible != true
        window?.showWindow(nil)
        if let mainWindow { window?.attach(to: mainWindow, centrePair: opening) }
        window?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var desktopScreenConfiguration: DesktopDisplayConfiguration {
        let screen = mainWindow?.screen ?? NSScreen.main
        let size = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        // Use the workspace aspect ratio to choose a stable desktop render resolution.
        // SDL uses top-left global desktop coordinates; Cocoa uses bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? size.height
        let frame = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        return DesktopDisplayConfiguration.fullScreenForWorkspace(width: Int(size.width), height: Int(size.height),
                                           windowX: Int(frame.midX - 320), windowY: Int(primaryTop - frame.midY - 200))
    }
    func closeStreams() {
        stop()
        window?.close()
        ScrcpyManager.shared.terminateSession()
    }
    func startDesktop(mode: DesktopMode? = nil) {
        if let mode { desktopMode = mode }
        UserDefaults.standard.set(desktopMode.rawValue, forKey: "desktopDisplayMode")
        let configuration = desktopMode == .windowed1080p ? DesktopDisplayConfiguration.windowed1080p : desktopScreenConfiguration
        stop()
        window?.close()
        ScrcpyManager.shared.launchScrcpy(phoneIp: ConnectionManager.shared.connectedIp, desktop: configuration) { [weak self] success, message in
            Task { @MainActor in
                guard let self else { return }
                self.status = success ? "Desktop mode is running in the scrcpy window." : message
                if !success { self.show() }
            }
        }
    }
    func start(packageName: String? = nil) {
        show()
        if isStreaming { if let packageName { send(["action": "launch", "packageName": packageName]) }; return }
        if isActive { return }
        guard ConnectionManager.shared.activeTransport == .wifi else {
            status = "Connect your phone to Droid Link over Wi-Fi to mirror its screen."; return
        }
        ScrcpyManager.shared.terminateSession()
        let id = UUID().uuidString
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        resumeAvailable = false; keepAwake = true; dimmed = false
        sessionId = id; isActive = true; status = "Requesting screen sharing…"
        frames = 0; fps = 0; lastFPS = Date()
        let playback = MirrorPlayback(sessionId: id, presenter: presenter, metadata: { [weak self] info in
            Task { @MainActor in self?.received(info, id: id) }
        }, failed: { [weak self] error in
            Task { @MainActor in self?.failed(error, id: id) }
        }, requestKeyframe: { [weak self] in Task { @MainActor in self?.send(["action": "keyframe"]) } })
        self.playback = playback
        let settings = quality; let audio = includeAudio
        let channel = MirrorChannel(sessionId: id, key: key, message: { [weak self] kind, payload in
            playback.receive(kind: kind, payload: payload)
            if kind == 1 { Task { @MainActor in self?.countFrame(id: id) } }
        }, failure: { [weak self] error in Task { @MainActor in self?.failed(error, id: id) } })
        self.channel = channel
        channel.start { [weak self] port in
            let offer = MirrorOffer(sessionId: id, key: key.base64EncodedString(), port: Int(port), maxSize: settings.size,
                                    fps: 60, bitrate: settings.bitrate, audio: audio, packageName: packageName)
            guard let bytes = try? JSONEncoder().encode(offer), let json = String(data: bytes, encoding: .utf8) else { return }
            Task { @MainActor in
                guard let self, self.sessionId == id else { return }
                ConnectionManager.shared.sendEnvelope(MessageEnvelope(type: .mirrorStart, payload: json)) { [weak self] accepted in
                    if !accepted { Task { @MainActor in self?.failed("Could not reach your phone. Reconnect and try again.", id: id) } }
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(125))
            guard !Task.isCancelled, let self, self.sessionId == id, !self.isStreaming else { return }
            self.failed("The sharing request expired. Unlock your phone and start again.", id: id)
        }
    }
    private func received(_ metadata: MirrorMetadata, id: String) {
        guard sessionId == id else { return }
        timeout?.cancel(); timeout = nil
        isStreaming = true; controlEnabled = metadata.control; audioActive = metadata.audio
        frameSize = CGSize(width: metadata.width, height: metadata.height)
        status = metadata.message ?? (metadata.control ? "Connected · remote control enabled" : "Connected · view only. Enable remote control in the phone's Accessibility settings.")
    }
    private func countFrame(id: String) {
        guard sessionId == id else { return }
        frames += 1
        let elapsed = Date().timeIntervalSince(lastFPS)
        if elapsed >= 1 { fps = Int(Double(frames) / elapsed); frames = 0; lastFPS = Date() }
    }
    func receiveStatus(_ response: MirrorStatus) {
        guard response.sessionId == sessionId else {
            // Android's lock status may arrive just after the media socket closes.
            if !isActive, response.sessionId == previousSessionId,
               Date().timeIntervalSince(previousStoppedAt) < 10,
               ["stopped", "error", "locked"].contains(response.state) {
                status = response.message; resumeAvailable = response.state == "locked"
            }
            return
        }
        if response.state == "stopped" || response.state == "error" || response.state == "locked" {
            stop(message: response.message, notifyPhone: false)
            resumeAvailable = response.state == "locked"
        }
        else if !isStreaming { status = response.message }
    }
    func transportChanged(_ transport: ActiveTransport) {
        if isActive && transport != .wifi { stop(message: "Screen sharing stopped because Wi-Fi disconnected.") }
    }
    private func failed(_ message: String, id: String) {
        guard sessionId == id else { return }
        stop(message: message)
    }
    func stop(message: String = "Screen sharing stopped", notifyPhone: Bool = true) {
        let old = sessionId
        if let old { previousSessionId = old; previousStoppedAt = Date() }
        timeout?.cancel(); timeout = nil
        if let playback { channel?.perform { playback.stop() } }
        channel?.stop(); channel = nil; playback = nil
        sessionId = nil; isActive = false; isStreaming = false; controlEnabled = false; audioActive = false; fps = 0
        status = message
        if notifyPhone, let old,
           let data = try? JSONEncoder().encode(["sessionId": old]), let json = String(data: data, encoding: .utf8) {
            ConnectionManager.shared.sendEnvelope(MessageEnvelope(type: .mirrorStop, payload: json))
        }
    }
    func send(_ command: [String: Any]) {
        guard isStreaming, let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        channel?.send(data)
    }
    func input(_ command: [String: Any]) { if controlEnabled { send(command) } }
    func setMuted(_ muted: Bool) {
        self.muted = muted
        if let playback { channel?.perform { playback.setMuted(muted) } }
    }
}
