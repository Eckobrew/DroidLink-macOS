import Foundation
import AVFoundation

/// One pending decoded image; replacing it is safe because H.264 decoding already completed.
final class MirrorFramePresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: MirrorPixelFrame?
    private var scheduled = false
    @MainActor weak var canvas: MirrorCanvas?
    func submit(_ frame: MirrorPixelFrame) {
        lock.lock(); latest = frame
        let schedule = !scheduled; scheduled = true; lock.unlock()
        if schedule { DispatchQueue.main.async { self.deliver() } }
    }
    @MainActor private func deliver() {
        lock.lock(); let frame = latest; latest = nil; scheduled = false; lock.unlock()
        if let frame { canvas?.display(frame) }
    }
    func clear() { lock.lock(); latest = nil; lock.unlock() }
}

final class MirrorAudioPlayer: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let lock = NSLock()
    private var queued = 0
    private var generation = UUID()
    var muted = false
    func consume(_ data: Data) throws {
        guard !muted, data.count > 0, data.count <= 19200, data.count % 4 == 0 else { return }
        if engine == nil {
            let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start(); player.play()
            self.engine = engine; self.player = player
        }
        lock.lock()
        if queued >= 6 { lock.unlock(); return } // Bound playback to about 60ms instead of accumulating delay.
        queued += 1; let token = generation; lock.unlock()
        let count = data.count / 4
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: UInt8.self)
            for index in 0..<count {
                for channel in 0..<2 {
                    let offset = index * 4 + channel * 2
                    let value = Int16(bitPattern: UInt16(values[offset]) | UInt16(values[offset + 1]) << 8)
                    channels[channel][index] = Float(value) / 32768
                }
            }
        }
        player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); if self.generation == token { self.queued = max(0, self.queued - 1) }; self.lock.unlock()
        }
    }
    func stop() {
        player?.stop(); engine?.stop(); player = nil; engine = nil
        lock.lock(); generation = UUID(); queued = 0; lock.unlock()
    }
}

/// Runs on MirrorChannel's serial media queue, including decoder teardown.
final class MirrorPlayback: @unchecked Sendable {
    let presenter: MirrorFramePresenter
    private var decoder: MirrorVideoDecoder?
    private let audio = MirrorAudioPlayer()
    private var size: (Int, Int)?
    private var muted = false
    private var failures = 0
    let metadata: @Sendable (MirrorMetadata) -> Void
    let failed: @Sendable (String) -> Void
    let requestKeyframe: @Sendable () -> Void
    private let sessionId: String
    init(sessionId: String, presenter: MirrorFramePresenter, metadata: @escaping @Sendable (MirrorMetadata) -> Void,
         failed: @escaping @Sendable (String) -> Void, requestKeyframe: @escaping @Sendable () -> Void) {
        self.sessionId = sessionId; self.presenter = presenter; self.metadata = metadata
        self.failed = failed; self.requestKeyframe = requestKeyframe
    }
    func receive(kind: UInt8, payload: Data) {
        do {
            switch kind {
            case 1:
                if decoder == nil { decoder = MirrorVideoDecoder { [presenter] frame in presenter.submit(frame) } }
                try decoder?.consume(MirrorVideoPacket(encoded: payload))
                failures = 0
            case 2:
                let info = try JSONDecoder().decode(MirrorMetadata.self, from: payload)
                guard info.sessionId == sessionId, (2...1920).contains(info.width), (2...1920).contains(info.height) else { throw CryptoError.decryptionFailed }
                if size?.0 != info.width || size?.1 != info.height { decoder?.reset(); size = (info.width, info.height) }
                if !info.audio { audio.stop() }
                metadata(info)
            case 5:
                audio.muted = muted
                try audio.consume(payload)
            case 6: break // heartbeat
            default: throw CryptoError.decryptionFailed
            }
        } catch {
            if kind == 1 {
                failures += 1; requestKeyframe()
                if failures > 10 { failed("Could not decode the phone's video stream. Try a lower quality setting.") }
            } else { failed("Invalid media stream: \(error.localizedDescription)") }
        }
    }
    func setMuted(_ value: Bool) { muted = value; if value { audio.stop() } }
    func stop() { decoder?.reset(); decoder = nil; audio.stop(); presenter.clear() }
}
