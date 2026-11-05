import Foundation

/// Decodes one complete packet after the media transport authenticates/decrypts it.
struct MirrorVideoPacket: Equatable {
    enum Kind: UInt8 { case frame = 0, keyFrame = 1, configuration = 2 }
    enum DecodeError: Error { case invalidHeader, invalidLength }

    static let headerSize = 14
    static let maximumPayload = 8 * 1024 * 1024
    let kind: Kind
    let presentationTimeUs: UInt64
    let payload: Data

    init(encoded: Data) throws {
        let bytes = [UInt8](encoded)
        guard bytes.count >= Self.headerSize, bytes[0] == 1,
              let kind = Kind(rawValue: bytes[1]) else { throw DecodeError.invalidHeader }
        let timestamp = bytes[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let length = bytes[10..<14].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard timestamp <= UInt64(Int64.max), length > 0,
              length <= Self.maximumPayload,
              bytes.count == Self.headerSize + Int(length) else { throw DecodeError.invalidLength }
        self.kind = kind
        self.presentationTimeUs = timestamp
        self.payload = Data(bytes.dropFirst(Self.headerSize))
    }
}
