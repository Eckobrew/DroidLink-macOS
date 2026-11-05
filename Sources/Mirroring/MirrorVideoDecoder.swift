import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

struct MirrorPixelFrame: @unchecked Sendable { let buffer: CVPixelBuffer }

/// Parses both Annex B output and AVC configuration records used by Android encoders.
enum MirrorH264 {
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        if !starts.isEmpty {
            return starts.indices.compactMap { index in
                let start = starts[index].1
                let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
                return end > start ? Data(bytes[start..<end]) : nil
            }
        }
        // Length-prefixed AVC access unit.
        var result: [Data] = []; i = 0
        while i + 4 <= bytes.count {
            let size = bytes[i..<i + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; i += 4
            guard size > 0, Int(size) <= bytes.count - i else { return [] }
            result.append(Data(bytes[i..<i + Int(size)])); i += Int(size)
        }
        return i == bytes.count ? result : []
    }
    static func parameterSets(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == 1 else { return nalUnits(data) }
        var result: [Data] = []; var offset = 6
        func readSets(_ count: Int) -> Bool {
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return false }
                let size = Int(bytes[offset]) * 256 + Int(bytes[offset + 1]); offset += 2
                guard size > 0, size <= bytes.count - offset else { return false }
                result.append(Data(bytes[offset..<offset + size])); offset += size
            }
            return true
        }
        guard readSets(Int(bytes[5] & 31)), offset < bytes.count else { return [] }
        let ppsCount = Int(bytes[offset]); offset += 1
        return readSets(ppsCount) ? result : []
    }
}

/// Called only on the media queue. No queue of decoded frames is retained here.
final class MirrorVideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKey = true
    private let output: @Sendable (MirrorPixelFrame) -> Void
    init(output: @escaping @Sendable (MirrorPixelFrame) -> Void) { self.output = output }
    deinit { reset() }
    func reset() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; sps = nil; pps = nil; waitingForKey = true
    }
    func consume(_ packet: MirrorVideoPacket) throws {
        let units = packet.kind == .configuration ? MirrorH264.parameterSets(packet.payload) : MirrorH264.nalUnits(packet.payload)
        guard !units.isEmpty else { throw DecodeFailure.invalidBitstream }
        let newSPS = units.first { ($0.first ?? 0) & 31 == 7 } ?? sps
        let newPPS = units.first { ($0.first ?? 0) & 31 == 8 } ?? pps
        if newSPS != sps || newPPS != pps {
            reset(); sps = newSPS; pps = newPPS
            if let sps, let pps { try configure(sps: sps, pps: pps) }
        }
        if packet.kind == .configuration { waitingForKey = true; return }
        if packet.kind == .keyFrame { waitingForKey = false }
        guard !waitingForKey, let session, let format else { return }
        var avcc = Data()
        for unit in units where ((unit.first ?? 0) & 31) != 7 && ((unit.first ?? 0) & 31) != 8 {
            var length = UInt32(unit.count).bigEndian
            avcc.append(withUnsafeBytes(of: &length) { Data($0) }); avcc.append(unit)
        }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block))
        guard let block else { throw DecodeFailure.invalidBitstream }
        try avcc.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count))
        }
        var size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(packet.presentationTimeUs), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
        guard let sample else { throw DecodeFailure.invalidBitstream }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { waitingForKey = true; throw DecodeFailure.status(status) }
    }
    private func configure(sps: Data, pps: Data) throws {
        var description: CMFormatDescription?
        let result = sps.withUnsafeBytes { spsBytes in pps.withUnsafeBytes { ppsBytes in
            let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sps.count, pps.count]
            return pointers.withUnsafeBufferPointer { pointers in sizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            } }
        } }
        try check(result)
        guard let description else { throw DecodeFailure.invalidBitstream }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard status == noErr, let ref, let image else { return }
            Unmanaged<MirrorVideoDecoder>.fromOpaque(ref).takeUnretainedValue().output(MirrorPixelFrame(buffer: image))
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &session))
        format = description
    }
    enum DecodeFailure: Error { case invalidBitstream, status(OSStatus) }
    private func check(_ status: OSStatus) throws { if status != noErr { throw DecodeFailure.status(status) } }
}
