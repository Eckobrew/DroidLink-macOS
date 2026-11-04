import XCTest
import CryptoKit
@testable import DroidDock

final class DroidDockTests: XCTestCase {
    func testCryptoKeyAgreementAndEncryption() throws {
        let macCrypto = CryptoManager()
        let androidCrypto = CryptoManager()

        let macPub = macCrypto.localPublicKeyBase64
        let androidPub = androidCrypto.localPublicKeyBase64

        XCTAssertFalse(macPub.isEmpty)
        XCTAssertFalse(androidPub.isEmpty)

        // Establish mutual shared keys
        try macCrypto.establishSharedKey(deviceId: "android_test_device", remotePublicKeyBase64: androidPub)
        try androidCrypto.establishSharedKey(deviceId: "mac_test_device", remotePublicKeyBase64: macPub)

        // Test encryption from Mac to Android
        let originalText = "Hello Android! RCS test message with E2EE."
        let plaintextData = originalText.data(using: .utf8)!

        let encryptedPacket = try macCrypto.encrypt(deviceId: "android_test_device", plaintext: plaintextData)
        XCTAssertGreaterThan(encryptedPacket.count, plaintextData.count)

        let decryptedData = try androidCrypto.decrypt(deviceId: "mac_test_device", packet: encryptedPacket)
        let decryptedText = String(data: decryptedData, encoding: .utf8)

        XCTAssertEqual(decryptedText, originalText)
    }

    func testReplayProtection() throws {
        let macCrypto = CryptoManager()
        let androidCrypto = CryptoManager()

        try macCrypto.establishSharedKey(deviceId: "android_test_device", remotePublicKeyBase64: androidCrypto.localPublicKeyBase64)
        try androidCrypto.establishSharedKey(deviceId: "mac_test_device", remotePublicKeyBase64: macCrypto.localPublicKeyBase64)

        let plaintext = "Packet 1".data(using: .utf8)!
        let packet = try macCrypto.encrypt(deviceId: "android_test_device", plaintext: plaintext)

        // First decryption should succeed
        _ = try androidCrypto.decrypt(deviceId: "mac_test_device", packet: packet)

        // Replaying the exact same packet must throw replayDetected error
        XCTAssertThrowsError(try androidCrypto.decrypt(deviceId: "mac_test_device", packet: packet)) { error in
            guard let cryptoError = error as? CryptoError else {
                XCTFail("Expected CryptoError")
                return
            }
            XCTAssertEqual(cryptoError, .replayDetected)
        }
    }

    func testEnvelopeSerialization() throws {
        let chatMsg = ChatMessage(
            threadId: "thread_123",
            senderName: "Alice",
            senderAddress: "+15551234567",
            isFromMe: false,
            text: "Testing RCS message envelope",
            timestamp: Date(),
            status: .delivered,
            messageType: .rcs
        )

        let jsonEncoder = JSONEncoder()
        let chatData = try jsonEncoder.encode(chatMsg)
        let chatJson = String(data: chatData, encoding: .utf8)!

        let envelope = MessageEnvelope(type: .chatMessage, payload: chatJson)
        let envData = try jsonEncoder.encode(envelope)

        let decodedEnv = try JSONDecoder().decode(MessageEnvelope.self, from: envData)
        XCTAssertEqual(decodedEnv.type, .chatMessage)

        let decodedMsg = try JSONDecoder().decode(ChatMessage.self, from: decodedEnv.payload.data(using: .utf8)!)
        XCTAssertEqual(decodedMsg.text, "Testing RCS message envelope")
        XCTAssertEqual(decodedMsg.messageType, .rcs)
    }

    func testPairingFingerprint() {
        let crypto = CryptoManager()
        let fingerprint = crypto.verificationFingerprint
        XCTAssertEqual(fingerprint.count, 6)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isNumber })
    }
}
