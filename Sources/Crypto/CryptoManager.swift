import Foundation
import CryptoKit

public enum CryptoError: Error, LocalizedError {
    case invalidPublicKey
    case noSharedKeyEstablished
    case encryptionFailed
    case decryptionFailed
    case replayDetected

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey: return "Invalid P-256 public key format."
        case .noSharedKeyEstablished: return "No shared secret established. Pair device first."
        case .encryptionFailed: return "Failed to encrypt payload."
        case .decryptionFailed: return "Failed to decrypt or authenticate payload."
        case .replayDetected: return "Replay attack detected: duplicate or out-of-order packet."
        }
    }
}

public final class CryptoManager: @unchecked Sendable {
    public static let shared = CryptoManager()

    private let lock = NSLock()
    private var privateKey: P256.KeyAgreement.PrivateKey
    private var sharedKeys: [String: SymmetricKey] = [:] // deviceId -> SymmetricKey
    private var lastInboundSequence: [String: UInt64] = [:]
    private var outboundSequence: UInt64 = 0

    public init() {
        // Load persistent private key from Keychain, or generate a fresh one
        if let storedKeyData = KeychainStore.load(key: "droiddock_ecdh_private_key"),
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: storedKeyData) {
            self.privateKey = key
        } else {
            let key = P256.KeyAgreement.PrivateKey()
            KeychainStore.save(key: "droiddock_ecdh_private_key", data: key.rawRepresentation)
            self.privateKey = key
        }
    }

    /// Exports the local public key in ANSI X9.63 uncompressed format (65 bytes), Base64 encoded.
    public var localPublicKeyBase64: String {
        lock.lock()
        defer { lock.unlock() }
        let pubData = privateKey.publicKey.x963Representation
        return pubData.base64EncodedString()
    }

    /// Computes a user-friendly 6-digit verification code / fingerprint from the public key
    public var verificationFingerprint: String {
        let pubData = Data(base64Encoded: localPublicKeyBase64) ?? Data()
        let hash = SHA256.hash(data: pubData)
        let hashBytes = Array(hash)
        let value = (UInt32(hashBytes[0]) << 16) | (UInt32(hashBytes[1]) << 8) | UInt32(hashBytes[2])
        return String(format: "%06d", value % 1_000_000)
    }

    /// Establishes an E2E shared secret with the remote peer's public key
    public func establishSharedKey(deviceId: String, remotePublicKeyBase64: String, salt: String = "DroidDock_E2EE_v1") throws {
        guard let pubData = Data(base64Encoded: remotePublicKeyBase64),
              let remotePublicKey = try? P256.KeyAgreement.PublicKey(x963Representation: pubData) else {
            throw CryptoError.invalidPublicKey
        }

        lock.lock()
        defer { lock.unlock() }

        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        let saltData = salt.data(using: .utf8) ?? Data()
        let infoData = "DroidDock_AES256GCM_Channel".data(using: .utf8) ?? Data()

        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: infoData,
            outputByteCount: 32
        )

        sharedKeys[deviceId] = symmetricKey
        lastInboundSequence.removeValue(forKey: deviceId)
        outboundSequence = 0
        KeychainStore.save(key: "droiddock_peer_key_\(deviceId)", data: pubData)
    }

    /// Restores a previously paired peer
    public func restorePairedDevice(deviceId: String) -> Bool {
        guard let pubData = KeychainStore.load(key: "droiddock_peer_key_\(deviceId)") else {
            return false
        }
        do {
            try establishSharedKey(deviceId: deviceId, remotePublicKeyBase64: pubData.base64EncodedString())
            return true
        } catch {
            return false
        }
    }

    /// Removes paired device key
    public func removePairedDevice(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        sharedKeys.removeValue(forKey: deviceId)
        lastInboundSequence.removeValue(forKey: deviceId)
        KeychainStore.delete(key: "droiddock_peer_key_\(deviceId)")
    }

    /// Encrypts plaintext bytes with AES-256-GCM.
    /// Wire format: [8-byte sequence][12-byte Nonce][Ciphertext + 16-byte GCM Tag]
    public func encrypt(deviceId: String, plaintext: Data) throws -> Data {
        lock.lock()
        var key = sharedKeys[deviceId]
        if key == nil, let first = sharedKeys.values.first {
            key = first
        }
        guard let symmetricKey = key else {
            lock.unlock()
            throw CryptoError.noSharedKeyEstablished
        }
        outboundSequence += 1
        let seq = outboundSequence
        lock.unlock()

        let nonce = AES.GCM.Nonce()
        guard let sealedBox = try? AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce) else {
            throw CryptoError.encryptionFailed
        }

        var packet = Data()
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { packet.append(contentsOf: $0) }
        packet.append(contentsOf: nonce)
        packet.append(sealedBox.ciphertext)
        packet.append(sealedBox.tag)
        return packet
    }

    /// Decrypts ciphertext bytes with AES-256-GCM, validating authentication tag and sequence order.
    public func decrypt(deviceId: String, packet: Data) throws -> Data {
        lock.lock()
        var key = sharedKeys[deviceId]
        if key == nil, let first = sharedKeys.values.first {
            key = first
        }
        guard let symmetricKey = key else {
            lock.unlock()
            throw CryptoError.noSharedKeyEstablished
        }
        lock.unlock()

        // Minimum length: 8 (seq) + 12 (nonce) + 16 (tag) = 36 bytes
        guard packet.count >= 36 else {
            throw CryptoError.decryptionFailed
        }

        let seqData = packet.prefix(8)
        let seq = seqData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }

        let nonceData = packet.subdata(in: 8..<20)
        let ciphertextAndTag = packet.suffix(from: 20)
        let tagData = ciphertextAndTag.suffix(16)
        let ciphertext = ciphertextAndTag.dropLast(16)

        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData),
              let decrypted = try? AES.GCM.open(sealedBox, using: symmetricKey) else {
            throw CryptoError.decryptionFailed
        }

        lock.lock()
        let lastSeq = lastInboundSequence[deviceId] ?? 0
        if seq <= lastSeq && seq != 1 && lastSeq != 0 {
            if seq <= 10 && lastSeq > 10 {
                // New session sequence reset from reconnected phone
                lastInboundSequence[deviceId] = seq
            } else {
                lock.unlock()
                print("[CryptoManager] Replay detected: seq=\(seq), lastSeq=\(lastSeq)")
                throw CryptoError.replayDetected
            }
        } else {
            lastInboundSequence[deviceId] = seq
        }
        lock.unlock()

        return decrypted
    }

    /// Resets sequence counters upon fresh socket connection
    public func resetSequenceCounters(for deviceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        outboundSequence = 0
        if let id = deviceId {
            lastInboundSequence.removeValue(forKey: id)
        } else {
            lastInboundSequence.removeAll()
        }
    }
}
