import Foundation
import CryptoKit

struct MirrorOffer: Codable, Sendable {
    let sessionId: String
    let key: String
    let port: Int
    let maxSize: Int
    let fps: Int
    let bitrate: Int
    let audio: Bool
    let packageName: String?
}

struct MirrorStatus: Codable, Sendable {
    let sessionId: String
    let state: String
    let message: String
}

struct MirrorMetadata: Codable, Sendable {
    let sessionId: String
    let width: Int
    let height: Int
    let control: Bool
    let audio: Bool
    let message: String?
}

/// Each session uses a new random 256-bit key delivered only over the paired E2EE channel.
/// Nonces: 4-byte direction (1 phone->Mac, 2 Mac->phone) + 8-byte sequence.
/// AAD: UTF-8 session ID + nonce. Wire record: sequence + ciphertext + GCM tag.
final class MirrorCipher {
    static let maximumRecordSize = MirrorVideoPacket.maximumPayload + 128
    private let key: SymmetricKey
    private let session: Data
    private let outgoingDirection: UInt32
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(key: Data, sessionId: String, isMac: Bool = true) throws {
        guard key.count == 32, UUID(uuidString: sessionId) != nil else { throw CryptoError.invalidPublicKey }
        self.key = SymmetricKey(data: key)
        session = Data(sessionId.utf8)
        outgoingDirection = isMac ? 2 : 1
    }

    private func nonce(direction: UInt32, sequence: UInt64) -> Data {
        var direction = direction.bigEndian
        var sequence = sequence.bigEndian
        return withUnsafeBytes(of: &direction) { Data($0) } + withUnsafeBytes(of: &sequence) { Data($0) }
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard sent < UInt64.max, !plaintext.isEmpty,
              plaintext.count + 24 <= Self.maximumRecordSize else { throw CryptoError.encryptionFailed }
        let sequence = sent + 1
        let nonceData = nonce(direction: outgoingDirection, sequence: sequence)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData), authenticating: session + nonceData)
        sent = sequence
        return nonceData.suffix(8) + box.ciphertext + box.tag
    }

    func open(_ record: Data) throws -> Data {
        guard record.count >= 25, record.count <= Self.maximumRecordSize, received < UInt64.max else { throw CryptoError.decryptionFailed }
        let sequence = record.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard sequence == received + 1 else { throw CryptoError.replayDetected }
        let nonceData = nonce(direction: outgoingDirection == 2 ? 1 : 2, sequence: sequence)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: record.dropFirst(8).dropLast(16), tag: record.suffix(16))
        let result = try AES.GCM.open(box, using: key, authenticating: session + nonceData)
        received = sequence
        return result
    }
}
