import XCTest
import CryptoKit
import AppKit
import ImageIO
@testable import DroidLink

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
    func testSequenceHeaderIsAuthenticated() throws {
        let sender = CryptoManager()
        let receiver = CryptoManager()
        try sender.establishSharedKey(deviceId: "receiver", remotePublicKeyBase64: receiver.localPublicKeyBase64)
        try receiver.establishSharedKey(deviceId: "sender", remotePublicKeyBase64: sender.localPublicKeyBase64)
        let packet = try sender.encrypt(deviceId: "receiver", plaintext: Data("hello".utf8))
        var tampered = packet
        tampered[7] = 100
        XCTAssertThrowsError(try receiver.decrypt(deviceId: "sender", packet: tampered))
        XCTAssertEqual(try receiver.decrypt(deviceId: "sender", packet: packet), Data("hello".utf8))
    }

    func testUnknownPeerCannotUseAnotherPeersKey() throws {
        let crypto = CryptoManager()
        try crypto.establishSharedKey(deviceId: "known", remotePublicKeyBase64: CryptoManager().localPublicKeyBase64)
        XCTAssertThrowsError(try crypto.encrypt(deviceId: "unknown", plaintext: Data()))
    }

    func testRepeatedMessagesArePreserved() {
        func message(_ id: String, thread: String = "alice", outgoing: Bool = false) -> ChatMessage {
            ChatMessage(id: id, threadId: thread, senderName: "Alice", senderAddress: thread,
                        isFromMe: outgoing, text: "OK", timestamp: Date(timeIntervalSince1970: 100),
                        status: .sent, messageType: .sms)
        }
        let messages = [message("sms_1"), message("sms_2"), message("sms_3", thread: "bob")]
        XCTAssertEqual(AppState.deduplicateMessageList(messages).count, 3)
        XCTAssertEqual(AppState.deduplicateMessageList([messages[0], messages[0]]).count, 1)
        XCTAssertEqual(AppState.deduplicateMessageList([
            message("local-uuid", outgoing: true), message("sms_4", outgoing: true)
        ]).count, 1)
    }

    func testSendStatusDoesNotRegress() {
        XCTAssertFalse(MessageDeliveryStatus.failed.canTransition(to: .sent))
        XCTAssertFalse(MessageDeliveryStatus.delivered.canTransition(to: .sending))
        XCTAssertFalse(MessageDeliveryStatus.read.canTransition(to: .sent))
        XCTAssertTrue(MessageDeliveryStatus.sending.canTransition(to: .failed))
        XCTAssertTrue(MessageDeliveryStatus.sent.canTransition(to: .delivered))
    }

    func testSmsFallbackStatusPayload() throws {
        let payload = Data(#"{"id":"outgoing-1","status":"failed","protocol":"SMS"}"#.utf8)
        let update = try JSONDecoder().decode([String: String].self, from: payload)
        XCTAssertEqual(update["protocol"].flatMap(MessageProtocolType.init(rawValue:)), .sms)
        XCTAssertEqual(update["status"].flatMap(MessageDeliveryStatus.init(rawValue:)), .failed)
    }

    func testImageOnlyMessageSurvivesSyncAndCacheRoundTrip() throws {
        let payload = Data(#"{"id":"mms_17","threadId":"alice","senderName":"Alice","senderAddress":"alice","isFromMe":false,"text":"","timestamp":1793810000000,"status":"delivered","messageType":"MMS","attachments":[{"url":"content://mms/part/5","mimeType":"image/jpeg"},{"url":"content://mms/part/6","mimeType":"image/png"}]}"#.utf8)
        let image = try JSONDecoder().decode(ChatMessage.self, from: payload)
        XCTAssertTrue(image.hasContent)
        XCTAssertEqual(AppState.deduplicateMessageList([image]).count, 1)
        let cached = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(image))
        XCTAssertEqual(cached.attachments.count, 2)
        XCTAssertEqual(cached.attachments[1].mimeType, "image/png")
    }

    func testLegacyTextMessageWithoutAttachmentsStillDecodes() throws {
        let payload = Data(#"{"id":"sms_18","threadId":"alice","text":"hello","messageType":"SMS"}"#.utf8)
        let text = try JSONDecoder().decode(ChatMessage.self, from: payload)
        XCTAssertTrue(text.attachments.isEmpty)
        XCTAssertTrue(text.hasContent)
    }

    func testBluetoothNameMatchingRejectsUnrelatedAndEmptyNames() {
        XCTAssertFalse(CallAudioManager.matchesPhoneName("", target: "Pixel"))
        XCTAssertFalse(CallAudioManager.matchesPhoneName("AirPods", target: "Pixel"))
        XCTAssertFalse(CallAudioManager.matchesPhoneName("Pixel 9", target: "Pixel 9 Pro"))
        XCTAssertTrue(CallAudioManager.matchesPhoneName("Google Pixel 9", target: "Pixel 9"))
    }

    func testCallTimestampRoundTripAndAndroidCallPayload() throws {
        let call = PhoneCall(phoneNumber: "+441234", state: .active, direction: .outgoing,
            startTime: Date(timeIntervalSince1970: 1793810000), duration: 42, isMuted: true)
        let data = try JSONEncoder().encode(call)
        let restored = try JSONDecoder().decode(PhoneCall.self, from: data)
        XCTAssertEqual(restored.startTime, call.startTime)
        XCTAssertEqual(restored.direction, .outgoing)
        XCTAssertTrue(restored.isMuted)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["startTime"] as? Double, 1793810000000)
    }

    @MainActor
    func testOverlappingBulkAndLiveImagesArePreserved() async throws {
        let state = AppState(startServices: false)
        state.selectedThreadId = "alice"
        let timestamp = Date()
        func image(_ id: String) -> ChatMessage {
            ChatMessage(id: id, threadId: "alice", senderName: "Alice", senderAddress: "alice", isFromMe: false,
                text: "", timestamp: timestamp, messageType: .mms,
                attachments: [MessageAttachment(url: "content://mms/part/" + id, mimeType: "image/jpeg")])
        }
        for chunk in 0..<10 {
            state.receiveBulkChatMessages((0..<100).map { image("mms_\(chunk * 100 + $0)") })
            state.receiveChatMessage(image("live_\(chunk)"))
            try await Task.sleep(for: .milliseconds(30))
        }
        for _ in 0..<200 {
            if state.activeThreadTotalCount == 1010 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(state.activeThreadTotalCount, 1010)
        XCTAssertEqual(state.threads.count, 1)
        XCTAssertTrue(state.activeThreadMessages.allSatisfy(\.hasContent))
    }

    func testSelectedImageIsResizedForPhoneComposer() throws {
        let context = CGContext(data: nil, width: 3200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 3200, height: 800))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = try MessageImageEncoder.jpeg(from: url)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, 400)
        XCTAssertLessThanOrEqual(data.count, 3_000_000)
    }

    @MainActor
    func testReplyAvailabilityRequiresLiveCapabilityAndConnection() {
        let state = AppState(startServices: false)
        state.messagingAppReplies["alice"] = true
        XCTAssertFalse(state.canUseMessagingApp(threadId: "alice"))
        state.activeTransport = .wifi
        XCTAssertTrue(state.canUseMessagingApp(threadId: "alice"))
        state.messagingAppReplies["alice"] = false
        XCTAssertFalse(state.canUseMessagingApp(threadId: "alice"))
        XCTAssertFalse(state.canUseMessagingApp(threadId: "bob"))
    }

    @MainActor
    func testGroupImageIsNotMergedIntoPersonalConversationOrSentAsSms() {
        let state = AppState(startServices: false)
        let personal = ChatMessage(id: "sms_42", threadId: "+441234", senderName: "Friends", senderAddress: "+441234", isFromMe: false, text: "Hello")
        state.receiveChatMessage(personal)
        let group = ChatMessage(id: "notification_image_abc", threadId: "notification_group_abc", senderName: "Friends",
            senderAddress: "Friends", isFromMe: false, text: "", messageType: .unknown,
            attachments: [MessageAttachment(url: "notification-image:abc", mimeType: "image/jpeg")])
        state.receiveChatMessage(group)
        XCTAssertEqual(state.threads.count, 2)
        state.sendMessage(to: "Friends", text: "Hello group", threadId: group.threadId, isRcs: false)
        XCTAssertNotNil(state.messageError)
    }

}
