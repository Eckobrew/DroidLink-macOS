import AppKit
import SwiftUI
import AVFoundation

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    private let manager: NativeMirrorManager
    private weak var mainWindow: NSWindow?
    private var alignmentObservers: [NSObjectProtocol] = []
    private var aligning = false
    private let gap: CGFloat = 8
    init(manager: NativeMirrorManager) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Droid Link — Phone Mirror"
        window.minSize = NSSize(width: 360, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MirrorWindowView(manager: manager))
        super.init(window: window)
        window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func attach(to main: NSWindow, centrePair: Bool = false) {
        guard main !== window else { return }
        for observer in alignmentObservers { NotificationCenter.default.removeObserver(observer) }
        alignmentObservers.removeAll()
        if let previous = mainWindow, let window { previous.removeChildWindow(window) }
        mainWindow = main
        if let window { main.addChildWindow(window, ordered: .above) }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            alignmentObservers.append(NotificationCenter.default.addObserver(forName: name, object: main, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.alignWithMain() }
            })
        }
        alignmentObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: main, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.close() }
        })
        if centrePair, let window, let screen = main.screen ?? NSScreen.main {
            let available = screen.visibleFrame
            let totalWidth = main.frame.width + gap + window.frame.width
            aligning = true
            main.setFrameOrigin(NSPoint(x: available.midX - totalWidth / 2,
                                        y: available.midY - main.frame.height / 2))
            aligning = false
        }
        alignWithMain()
    }
    private func alignWithMain() {
        guard !aligning, let mainWindow, let window, window.isVisible else { return }
        aligning = true
        window.setFrameOrigin(NSPoint(x: mainWindow.frame.maxX + gap, y: mainWindow.frame.midY - window.frame.height / 2))
        aligning = false
    }
    func windowDidMove(_ notification: Notification) {
        guard !aligning, let mainWindow, let window else { return }
        let origin = NSPoint(x: window.frame.minX - gap - mainWindow.frame.width,
                             y: window.frame.midY - mainWindow.frame.height / 2)
        guard abs(origin.x - mainWindow.frame.minX) > 0.5 || abs(origin.y - mainWindow.frame.minY) > 0.5 else { return }
        aligning = true
        mainWindow.setFrameOrigin(origin)
        // AppKit moves child windows with their parent. Restore the dragged child's desired position.
        window.setFrameOrigin(NSPoint(x: origin.x + mainWindow.frame.width + gap,
                                      y: origin.y + mainWindow.frame.height / 2 - window.frame.height / 2))
        aligning = false
    }
    func windowDidResize(_ notification: Notification) { alignWithMain() }
    func windowWillClose(_ notification: Notification) {
        manager.stop()
        if let mainWindow, let window { mainWindow.removeChildWindow(window) }
        for observer in alignmentObservers { NotificationCenter.default.removeObserver(observer) }
        alignmentObservers.removeAll()
    }
    func windowDidResignKey(_ notification: Notification) { manager.presenter.canvas?.releasePointer() }
}

private struct MirrorWindowView: View {
    @ObservedObject var manager: NativeMirrorManager
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { manager.input(["action": "back"]) } label: { Image(systemName: "chevron.backward") }.help("Back (Escape)")
                Button { manager.input(["action": "home"]) } label: { Image(systemName: "house") }.help("Home")
                Button { manager.input(["action": "recents"]) } label: { Image(systemName: "square.on.square") }.help("Recent apps")
                Spacer()
                if manager.audioActive {
                    Button { manager.setMuted(!manager.muted) } label: { Image(systemName: manager.muted ? "speaker.slash" : "speaker.wave.2") }.help("Mute phone audio on Mac")
                }
                if manager.isActive {
                    Button("Stop") { manager.stop() }
                } else {
                    Button(manager.resumeAvailable ? "Resume" : "Start") { manager.start() }.buttonStyle(.borderedProminent)
                }
            }
            .buttonStyle(.bordered).padding(10)
            if !manager.isActive {
                HStack {
                    Picker("Quality", selection: $manager.quality) {
                        ForEach(NativeMirrorManager.MirrorQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
                    }
                    Toggle("Phone audio", isOn: $manager.includeAudio)
                }.font(.caption).padding(.horizontal, 12).padding(.bottom, 10)
            }
            if manager.isStreaming {
                HStack {
                    Toggle("Keep phone awake", isOn: Binding(get: { manager.keepAwake }, set: {
                        manager.keepAwake = $0; manager.input(["action": "keepAwake", "enabled": $0])
                    })).disabled(!manager.controlEnabled)
                    Spacer()
                    Button(manager.dimmed ? "Restore brightness" : "Dim phone") {
                        manager.dimmed.toggle(); manager.input(["action": "dim", "enabled": manager.dimmed])
                    }.disabled(!manager.controlEnabled || !manager.keepAwake)
                }.font(.caption).padding(.horizontal, 10).padding(.bottom, 8)
            }
            ZStack {
                Color.black
                MirrorCanvasView(manager: manager)
                if !manager.isStreaming {
                    VStack(spacing: 12) {
                        Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 40))
                        if manager.isActive { ProgressView().controlSize(.small) }
                        Text(manager.status).multilineTextAlignment(.center).frame(maxWidth: 300)
                        if manager.isActive { Text("Approve sharing on your phone").font(.caption).foregroundStyle(.secondary) }
                    }.foregroundStyle(.white).padding(24)
                }
            }
            HStack(spacing: 8) {
                Circle().fill(manager.isStreaming ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(manager.status).font(.caption).lineLimit(3)
                Spacer()
                if manager.isStreaming { Text("\(manager.fps) fps").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if manager.isStreaming && !manager.controlEnabled {
                    Button("Enable control") { manager.send(["action": "controlSettings"]) }.font(.caption)
                }
            }.padding(10)
        }
    }
}

private struct MirrorCanvasView: NSViewRepresentable {
    @ObservedObject var manager: NativeMirrorManager
    func makeNSView(context: Context) -> MirrorCanvas {
        let canvas = MirrorCanvas()
        manager.presenter.canvas = canvas
        canvas.input = { [weak manager] command in manager?.input(command) }
        return canvas
    }
    func updateNSView(_ canvas: MirrorCanvas, context: Context) {
        canvas.videoSize = manager.frameSize
        canvas.enabled = manager.isStreaming && manager.controlEnabled
        if !manager.isStreaming { canvas.clear() }
    }
}

@MainActor
final class MirrorCanvas: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    var videoSize = CGSize(width: 720, height: 1280)
    var enabled = false
    var input: (([String: Any]) -> Void)?
    private var pressed = false
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var lastMove = Date.distantPast
    private var lastScroll = Date.distantPast
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect; layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); videoLayer.frame = bounds }
    func display(_ frame: MirrorPixelFrame) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if videoLayer.sampleBufferRenderer.status == .failed { videoLayer.sampleBufferRenderer.flush() }
        videoLayer.sampleBufferRenderer.enqueue(sample)
    }
    func clear() { releasePointer(); videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) }
    private var contentRect: CGRect {
        let scale = min(bounds.width / max(1, videoSize.width), bounds.height / max(1, videoSize.height))
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = contentRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func sendPointer(_ action: String) { input?(["action": action, "x": pointer.x, "y": pointer.y]) }
    override func mouseDown(with event: NSEvent) {
        guard enabled, let point = point(event) else { return }
        window?.makeFirstResponder(self); pointer = point; pressed = true; sendPointer("down")
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, pressed, let point = point(event, clamp: true) else { return }
        pointer = point
        if Date().timeIntervalSince(lastMove) >= 0.008 { lastMove = Date(); sendPointer("move") }
    }
    override func mouseUp(with event: NSEvent) {
        if let point = point(event, clamp: true) { pointer = point }; releasePointer()
    }
    func releasePointer() { if pressed { sendPointer("up"); pressed = false } }
    override func rightMouseDown(with event: NSEvent) { if enabled { input?(["action": "back"]) } }
    override func scrollWheel(with event: NSEvent) {
        guard enabled, Date().timeIntervalSince(lastScroll) > 0.08 else { return }
        lastScroll = Date()
        input?(["action": "scroll", "dy": max(-0.4, min(0.4, -event.scrollingDeltaY / 100))])
    }
    override func keyDown(with event: NSEvent) {
        guard enabled else { return }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", let text = NSPasteboard.general.string(forType: .string) { input?(["action": "text", "text": String(text.prefix(4096))]) }
            else if event.charactersIgnoringModifiers == "a" { input?(["action": "selectAll"]) }
            else { super.keyDown(with: event) }
            return
        }
        switch event.keyCode {
        case 53: input?(["action": "back"])
        case 51, 117: input?(["action": "delete"])
        case 36, 76: input?(["action": "enter"])
        case 123: input?(["action": "cursor", "direction": -1])
        case 124: input?(["action": "cursor", "direction": 1])
        default:
            if let text = event.characters, !text.isEmpty,
               text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { input?(["action": "text", "text": text]) }
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if enabled, event.modifierFlags.contains(.command), ["v", "a"].contains(event.charactersIgnoringModifiers ?? "") { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Records the actual SwiftUI main window without replacing its delegate.
struct MirrorMainWindowAnchor: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.identifier = NSUserInterfaceItemIdentifier("DroidLinkMain")
                NativeMirrorManager.shared.attachMainWindow(window)
            }
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) {}
}
