import Foundation

/// BLE carries the same four-byte big-endian length prefix as TCP. ATT packet
/// boundaries are deliberately unrelated to application frame boundaries.
public enum BLEFrameError: Error, Equatable { case invalidLength, queueFull }

public struct BLEFrameDecoder {
    public static let maximumFrameSize = 8 * 1024 * 1024
    private var header = Data()
    private var payload = Data()
    private var expected: Int?

    public init() {}
    public mutating func reset() { header.removeAll(); payload.removeAll(); expected = nil }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        var offset = 0
        var frames: [Data] = []
        while offset < bytes.count {
            if expected == nil {
                let count = min(4 - header.count, bytes.count - offset)
                header.append(bytes.subdata(in: offset..<(offset + count)))
                offset += count
                guard header.count == 4 else { continue }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 && length <= Self.maximumFrameSize else {
                    reset()
                    throw BLEFrameError.invalidLength
                }
                expected = length
                header.removeAll(keepingCapacity: true)
                payload.reserveCapacity(length)
            }
            if let length = expected {
                let count = min(length - payload.count, bytes.count - offset)
                payload.append(bytes.subdata(in: offset..<(offset + count)))
                offset += count
                if payload.count == length {
                    frames.append(payload)
                    payload = Data()
                    expected = nil
                }
            }
        }
        return frames
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumFrameSize else { throw BLEFrameError.invalidLength }
        var length = UInt32(payload.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(payload)
        return data
    }
}

/// Peek/commit lets CoreBluetooth apply backpressure without dropping or
/// advancing a fragment when updateValue returns false.
struct BLEFrameQueue {
    private struct Entry { let id: UUID; let data: Data; var offset = 0 }
    private var entries: [Entry] = []
    private(set) var remainingBytes = 0
    var isEmpty: Bool { entries.isEmpty }

    mutating func enqueue(_ data: Data, id: UUID) throws {
        let frame = try BLEFrameDecoder.encode(data)
        guard entries.count < 128, remainingBytes + frame.count <= 16 * 1024 * 1024 else { throw BLEFrameError.queueFull }
        entries.append(Entry(id: id, data: frame))
        remainingBytes += frame.count
    }

    func peek(maximumLength: Int) -> Data? {
        guard let first = entries.first, maximumLength > 0 else { return nil }
        return first.data.subdata(in: first.offset..<min(first.data.count, first.offset + maximumLength))
    }

    mutating func commit(_ count: Int) -> UUID? {
        precondition(!entries.isEmpty && count > 0 && count <= entries[0].data.count - entries[0].offset)
        entries[0].offset += count
        remainingBytes -= count
        if entries[0].offset == entries[0].data.count { return entries.removeFirst().id }
        return nil
    }
    mutating func reset() { entries.removeAll(); remainingBytes = 0 }
}

/// CoreBluetooth may deliver a long write as contiguous attribute fragments.
/// Validate the whole batch, then respond once to its first ATT request.
enum BLEWriteBatch {
    static func flatten(_ parts: [(offset: Int, value: Data)]) throws -> Data {
        var result = Data()
        var attributeLength = 0
        for (index, part) in parts.enumerated() {
            guard !part.value.isEmpty, part.value.count <= 512, index != 0 || part.offset == 0 else { throw BLEFrameError.invalidLength }
            if part.offset == 0 { attributeLength = 0 }
            guard part.offset == attributeLength, attributeLength + part.value.count <= 512 else { throw BLEFrameError.invalidLength }
            result.append(part.value)
            attributeLength += part.value.count
        }
        return result
    }
}
