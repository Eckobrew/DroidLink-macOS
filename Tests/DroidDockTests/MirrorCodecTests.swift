import XCTest
import VideoToolbox
import CoreMedia
import CoreVideo
@testable import DroidLink

final class MirrorCodecTests: XCTestCase {
    private final class EncodedOutput: @unchecked Sendable {
        let lock = NSLock()
        var sample: CMSampleBuffer?
        var status: OSStatus = noErr
    }
    private final class DecodedOutput: @unchecked Sendable {
        let lock = NSLock()
        var size: (Int, Int)?
    }
    func testH264EncodeAuthenticatedPacketAndDecode() throws {
        let output = EncodedOutput()
        var encoder: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 64, height: 64, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, sample in
                guard let ref else { return }
                let output = Unmanaged<EncodedOutput>.fromOpaque(ref).takeUnretainedValue()
                output.lock.lock(); output.status = status; output.sample = sample; output.lock.unlock()
            }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &encoder)
        guard created == noErr, let encoder else { throw XCTSkip("No H.264 encoder available on this host (\(created))") }
        defer { VTCompressionSessionInvalidate(encoder) }
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue), noErr)
        XCTAssertEqual(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        CVPixelBufferGetBaseAddress(pixelBuffer)?.initializeMemory(as: UInt8.self, repeating: 127, count: CVPixelBufferGetBytesPerRow(pixelBuffer) * 64)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        XCTAssertEqual(VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        XCTAssertEqual(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid), noErr)
        let sample = try XCTUnwrap(output.sample)
        XCTAssertEqual(output.status, noErr)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        var configuration = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), noErr)
            configuration.append(contentsOf: [0, 0, 0, 1]); configuration.append(Data(bytes: try XCTUnwrap(pointer), count: size))
        }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let count = avcc.count
        XCTAssertEqual(avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }, noErr)
        let decoded = DecodedOutput()
        let decoder = MirrorVideoDecoder { frame in
            decoded.lock.lock(); decoded.size = (CVPixelBufferGetWidth(frame.buffer), CVPixelBufferGetHeight(frame.buffer)); decoded.lock.unlock()
        }
        let id = "00000000-0000-0000-0000-000000000001"
        let phone = try MirrorCipher(key: Data(0..<32), sessionId: id, isMac: false)
        let mac = try MirrorCipher(key: Data(0..<32), sessionId: id)
        for (kind, payload) in [(UInt8(2), configuration), (UInt8(1), avcc)] {
            var length = UInt32(payload.count).bigEndian
            let packet = Data([1, kind]) + Data(repeating: 0, count: 8) + withUnsafeBytes(of: &length) { Data($0) } + payload
            try decoder.consume(MirrorVideoPacket(encoded: mac.open(phone.seal(packet))))
        }
        decoder.reset()
        XCTAssertEqual(decoded.size?.0, 64)
        XCTAssertEqual(decoded.size?.1, 64)
    }
}
