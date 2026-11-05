import Foundation

// MARK: - Envelope Protocol
public struct MessageEnvelope: Codable, Sendable {
    public let id: String
    public let type: EnvelopeType
    public let timestamp: Int64
    public let payload: String // JSON payload or encrypted Base64 string

    public init(id: String = UUID().uuidString, type: EnvelopeType, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000), payload: String) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.payload = payload
    }
}

public enum EnvelopeType: String, Codable, Sendable {
    case pairingRequest = "pairing_request"
    case pairingResponse = "pairing_response"
    case transportProbe = "transport_probe"
    case transportEndpoints = "transport_endpoints"
    case envelopeAck = "envelope_ack"
    case heartbeat = "heartbeat"
    case chatMessage = "chat_message"
    case chatSync = "chat_sync"
    case chatCapabilities = "chat_capabilities"
    case attachmentRequest = "attachment_request"
    case attachmentData = "attachment_data"
    case chatSend = "chat_send"
    case chatStatusUpdate = "chat_status_update"
    case callSync = "call_sync"
    case callIncoming = "call_incoming"
    case callStateUpdate = "call_state_update"
    case callActionResult = "call_action_result"
    case callAction = "call_action"
    case bluetoothPairRequest = "bluetooth_pair_request"
    case bluetoothPairResponse = "bluetooth_pair_response"
    case deviceStatus = "device_status"
    case contactSync = "contact_sync"
    case appSync = "app_sync"
    case appLaunch = "app_launch"
    case notificationSync = "notification_sync"
    case notificationPosted = "notification_posted"
    case notificationRemoved = "notification_removed"
    case notificationDismiss = "notification_dismiss"
    case mediaControl = "media_control"
    case unpair = "unpair"
}

// MARK: - Pairing Models
public struct PairingPayload: Codable, Sendable {
    public let version: Int
    public let deviceId: String
    public let deviceName: String
    public let publicKey: String // Base64 encoded ECDH P-256 public key
    public let wifiPort: Int
    public let wifiIps: [String]
    public let hostName: String?
    public let bleServiceUuid: String
    public let pairingNonce: String
    public let timestamp: Int64

    public init(
        version: Int = 1,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        wifiPort: Int = 8765,
        wifiIps: [String],
        hostName: String? = nil,
        bleServiceUuid: String,
        pairingNonce: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.version = version
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.wifiPort = wifiPort
        self.wifiIps = wifiIps
        self.hostName = hostName
        self.bleServiceUuid = bleServiceUuid
        self.pairingNonce = pairingNonce
        self.timestamp = timestamp
    }
}

public struct PairingConfirmation: Codable, Sendable {
    public let status: String // "accepted" or "rejected"
    public let deviceId: String
    public let deviceName: String
    public let publicKey: String
    public let nonceResponse: String

    public init(status: String, deviceId: String, deviceName: String, publicKey: String, nonceResponse: String) {
        self.status = status
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.nonceResponse = nonceResponse
    }
}

public struct PairedDevice: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var publicKey: String
    public var lastSeen: Date
    public var transportType: String
    public var isTrusted: Bool

    public init(id: String, name: String, publicKey: String, lastSeen: Date = Date(), transportType: String = "wifi", isTrusted: Bool = true) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.lastSeen = lastSeen
        self.transportType = transportType
        self.isTrusted = isTrusted
    }
}

// MARK: - Messages & RCS Models
public enum MessageProtocolType: String, Codable, Sendable {
    case unknown = "Unconfirmed"
    case rcs = "RCS"
    case sms = "SMS"
    case mms = "MMS"
}

public enum MessageDeliveryStatus: String, Codable, Sendable {
    case sending = "sending"
    case sent = "sent"
    case delivered = "delivered"
    case read = "read"
    case onPhone = "on_phone"
    case failed = "failed"

    public func canTransition(to next: MessageDeliveryStatus) -> Bool {
        switch self {
        case .sending: return true
        case .sent: return next == .delivered || next == .read || next == .failed
        case .delivered: return next == .read
        case .onPhone: return next == .sent || next == .delivered || next == .failed
        case .read, .failed: return false
        }
    }
}

public struct MessageAttachment: Codable, Hashable, Sendable {
    public let url: String
    public let mimeType: String
    public init(url: String, mimeType: String) { self.url = url; self.mimeType = mimeType }
}

public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let threadId: String
    public let senderName: String
    public let senderAddress: String
    public let isFromMe: Bool
    public let text: String
    public let timestamp: Date
    public var status: MessageDeliveryStatus
    public var messageType: MessageProtocolType
    public let attachmentUrl: String?
    public let attachmentMimeType: String?
    public let attachments: [MessageAttachment]
    public var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || attachmentUrl != nil }

    private enum CodingKeys: String, CodingKey {
        case id, threadId, senderName, senderAddress, isFromMe, text, timestamp, status, messageType, attachmentUrl, attachmentMimeType, attachments
    }

    public init(
        id: String = UUID().uuidString,
        threadId: String,
        senderName: String,
        senderAddress: String,
        isFromMe: Bool,
        text: String,
        timestamp: Date = Date(),
        status: MessageDeliveryStatus = .sent,
        messageType: MessageProtocolType = .rcs,
        attachmentUrl: String? = nil,
        attachmentMimeType: String? = nil,
        attachments: [MessageAttachment] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.isFromMe = isFromMe
        self.text = text
        self.timestamp = timestamp
        self.status = status
        self.messageType = messageType
        self.attachmentUrl = attachmentUrl
        self.attachmentMimeType = attachmentMimeType
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.threadId = try container.decode(String.self, forKey: .threadId)
        self.senderName = (try? container.decode(String.self, forKey: .senderName)) ?? ""
        self.senderAddress = (try? container.decode(String.self, forKey: .senderAddress)) ?? ""
        self.isFromMe = (try? container.decode(Bool.self, forKey: .isFromMe)) ?? false
        self.text = (try? container.decode(String.self, forKey: .text)) ?? ""
        self.status = (try? container.decode(MessageDeliveryStatus.self, forKey: .status)) ?? .delivered
        self.messageType = (try? container.decode(MessageProtocolType.self, forKey: .messageType)) ?? .unknown
        self.attachmentUrl = try? container.decodeIfPresent(String.self, forKey: .attachmentUrl)
        self.attachmentMimeType = try? container.decodeIfPresent(String.self, forKey: .attachmentMimeType)
        self.attachments = (try? container.decode([MessageAttachment].self, forKey: .attachments)) ?? []

        if let ts = try? container.decode(Double.self, forKey: .timestamp) {
            if ts > 1_000_000_000_000 {
                // Milliseconds since 1970 (e.g. from Android)
                self.timestamp = Date(timeIntervalSince1970: ts / 1000.0)
            } else if ts > 400_000_000 && ts < 1_200_000_000 {
                // Legacy cache saved with Apple's timeIntervalSinceReferenceDate (seconds since Jan 1 2001)
                self.timestamp = Date(timeIntervalSinceReferenceDate: ts)
            } else {
                self.timestamp = Date(timeIntervalSince1970: ts)
            }
        } else {
            self.timestamp = (try? container.decode(Date.self, forKey: .timestamp)) ?? Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(senderName, forKey: .senderName)
        try container.encode(senderAddress, forKey: .senderAddress)
        try container.encode(isFromMe, forKey: .isFromMe)
        try container.encode(text, forKey: .text)
        try container.encode(status, forKey: .status)
        try container.encode(messageType, forKey: .messageType)
        try container.encodeIfPresent(attachmentUrl, forKey: .attachmentUrl)
        try container.encodeIfPresent(attachmentMimeType, forKey: .attachmentMimeType)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(timestamp.timeIntervalSince1970 * 1000.0, forKey: .timestamp)
    }
}

public struct ChatThread: Codable, Identifiable, Sendable {
    public let id: String
    public var contactName: String
    public var contactAddress: String
    public var lastMessage: String
    public var lastMessageDate: Date
    public var unreadCount: Int
    public var isRcs: Bool
    public var isTyping: Bool

    private enum CodingKeys: String, CodingKey {
        case id, contactName, contactAddress, lastMessage, lastMessageDate, unreadCount, isRcs, isTyping
    }

    public init(
        id: String,
        contactName: String,
        contactAddress: String,
        lastMessage: String,
        lastMessageDate: Date = Date(),
        unreadCount: Int = 0,
        isRcs: Bool = true,
        isTyping: Bool = false
    ) {
        self.id = id
        self.contactName = contactName
        self.contactAddress = contactAddress
        self.lastMessage = lastMessage
        self.lastMessageDate = lastMessageDate
        self.unreadCount = unreadCount
        self.isRcs = isRcs
        self.isTyping = isTyping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.contactName = (try? container.decode(String.self, forKey: .contactName)) ?? id
        self.contactAddress = (try? container.decode(String.self, forKey: .contactAddress)) ?? id
        self.lastMessage = (try? container.decode(String.self, forKey: .lastMessage)) ?? ""
        self.unreadCount = (try? container.decode(Int.self, forKey: .unreadCount)) ?? 0
        self.isRcs = (try? container.decode(Bool.self, forKey: .isRcs)) ?? false
        self.isTyping = (try? container.decode(Bool.self, forKey: .isTyping)) ?? false

        if let ts = try? container.decode(Double.self, forKey: .lastMessageDate) {
            if ts > 1_000_000_000_000 {
                self.lastMessageDate = Date(timeIntervalSince1970: ts / 1000.0)
            } else if ts > 400_000_000 && ts < 1_200_000_000 {
                self.lastMessageDate = Date(timeIntervalSinceReferenceDate: ts)
            } else {
                self.lastMessageDate = Date(timeIntervalSince1970: ts)
            }
        } else {
            self.lastMessageDate = (try? container.decode(Date.self, forKey: .lastMessageDate)) ?? Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(contactName, forKey: .contactName)
        try container.encode(contactAddress, forKey: .contactAddress)
        try container.encode(lastMessage, forKey: .lastMessage)
        try container.encode(lastMessageDate.timeIntervalSince1970 * 1000.0, forKey: .lastMessageDate)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(isRcs, forKey: .isRcs)
        try container.encode(isTyping, forKey: .isTyping)
    }
}

public struct OutgoingMessageRequest: Codable, Sendable {
    public let id: String
    public let threadId: String
    public let recipient: String
    public let text: String
    public let preferRcs: Bool
    public var imageBase64: String? = nil

    public init(id: String = UUID().uuidString, threadId: String, recipient: String, text: String, preferRcs: Bool = true) {
        self.id = id
        self.threadId = threadId
        self.recipient = recipient
        self.text = text
        self.preferRcs = preferRcs
    }
}

// MARK: - Phone Calls Models
public enum CallState: String, Codable, Sendable {
    case incoming = "incoming"
    case dialing = "dialing"
    case ringing = "ringing"
    case active = "active"
    case held = "held"
    case ended = "ended"
    case missed = "missed"
    case rejected = "rejected"
}

public enum CallDirection: String, Codable, Sendable {
    case incoming = "incoming"
    case outgoing = "outgoing"
}

public struct PhoneCall: Codable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, phoneNumber, contactName, state, direction, startTime, duration, isMuted, isSpeaker
    }
    public let id: String
    public let phoneNumber: String
    public var contactName: String
    public var state: CallState
    public let direction: CallDirection
    public var startTime: Date?
    public var duration: TimeInterval
    public var isMuted: Bool
    public var isSpeaker: Bool

    public init(
        id: String = UUID().uuidString,
        phoneNumber: String,
        contactName: String = "",
        state: CallState = .incoming,
        direction: CallDirection = .incoming,
        startTime: Date? = nil,
        duration: TimeInterval = 0,
        isMuted: Bool = false,
        isSpeaker: Bool = false
    ) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.contactName = contactName.isEmpty ? phoneNumber : contactName
        self.state = state
        self.direction = direction
        self.startTime = startTime
        self.duration = duration
        self.isMuted = isMuted
        self.isSpeaker = isSpeaker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.phoneNumber = try container.decode(String.self, forKey: .phoneNumber)
        self.contactName = (try? container.decodeIfPresent(String.self, forKey: .contactName)) ?? phoneNumber
        self.state = (try? container.decode(CallState.self, forKey: .state)) ?? .ended
        self.direction = (try? container.decode(CallDirection.self, forKey: .direction)) ?? .incoming
        self.duration = (try? container.decode(TimeInterval.self, forKey: .duration)) ?? 0
        self.isMuted = (try? container.decode(Bool.self, forKey: .isMuted)) ?? false
        self.isSpeaker = (try? container.decode(Bool.self, forKey: .isSpeaker)) ?? false

        if let dateMs = try? container.decode(Double.self, forKey: .startTime) {
            self.startTime = Date(timeIntervalSince1970: dateMs > 1_000_000_000_000 ? dateMs / 1000.0 : dateMs)
        } else {
            self.startTime = try? container.decode(Date.self, forKey: .startTime)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(phoneNumber, forKey: .phoneNumber)
        try container.encode(contactName, forKey: .contactName)
        try container.encode(state, forKey: .state)
        try container.encode(direction, forKey: .direction)
        try container.encodeIfPresent(startTime.map { $0.timeIntervalSince1970 * 1000 }, forKey: .startTime)
        try container.encode(duration, forKey: .duration)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(isSpeaker, forKey: .isSpeaker)
    }

}

public enum CallActionType: String, Codable, Sendable {
    case dial = "dial"
    case answer = "answer"
    case reject = "reject"
    case hangup = "hangup"
    case mute = "mute"
    case unmute = "unmute"
    case dtmf = "dtmf"
    case audioPhone = "audio_phone"
    case audioSpeaker = "audio_speaker"
    case audioBluetooth = "audio_bluetooth"
}

public struct CallActionPayload: Codable, Sendable {
    public let callId: String?
    public let action: CallActionType
    public let number: String?
    public let dtmfDigit: String?

    public init(callId: String? = nil, action: CallActionType, number: String? = nil, dtmfDigit: String? = nil) {
        self.callId = callId
        self.action = action
        self.number = number
        self.dtmfDigit = dtmfDigit
    }
}

// MARK: - Device Status
public struct DeviceStatusPayload: Codable, Sendable {
    public let batteryLevel: Int
    public let isCharging: Bool
    public let wifiSsid: String?
    public let cellularCarrier: String?
    public let cellularSignalStrength: Int
    public let isBluetoothAudioConnected: Bool

    public init(
        batteryLevel: Int,
        isCharging: Bool,
        wifiSsid: String? = nil,
        cellularCarrier: String? = nil,
        cellularSignalStrength: Int = 4,
        isBluetoothAudioConnected: Bool = false
    ) {
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.wifiSsid = wifiSsid
        self.cellularCarrier = cellularCarrier
        self.cellularSignalStrength = cellularSignalStrength
        self.isBluetoothAudioConnected = isBluetoothAudioConnected
    }
}

// MARK: - Contacts
public struct ContactItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let phoneNumbers: [String]
    public let email: String?

    public init(id: String = UUID().uuidString, name: String, phoneNumbers: [String], email: String? = nil) {
        self.id = id
        self.name = name
        self.phoneNumbers = phoneNumbers
        self.email = email
    }
}

// MARK: - Installed Apps
public struct InstalledApp: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let packageName: String
    public let versionName: String?
    public let iconBase64: String?
    public let isSystemApp: Bool

    public init(id: String, name: String, packageName: String, versionName: String? = nil, iconBase64: String? = nil, isSystemApp: Bool = false) {
        self.id = id
        self.name = name
        self.packageName = packageName
        self.versionName = versionName
        self.iconBase64 = iconBase64
        self.isSystemApp = isSystemApp
    }
}

// MARK: - Notifications
public struct AppNotification: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let text: String
    public let subText: String?
    public let timestamp: Int64
    public let iconBase64: String?
    public let canReply: Bool
    public let isClearable: Bool
    public let isMediaPlayback: Bool?

    public init(
        id: String,
        packageName: String,
        appName: String,
        title: String,
        text: String,
        subText: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        iconBase64: String? = nil,
        canReply: Bool = false,
        isClearable: Bool = true,
        isMediaPlayback: Bool? = false
    ) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.text = text
        self.subText = subText
        self.timestamp = timestamp
        self.iconBase64 = iconBase64
        self.canReply = canReply
        self.isClearable = isClearable
        self.isMediaPlayback = isMediaPlayback
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
    }
}
