import Foundation
import SwiftUI
import Combine
import IOBluetooth
import UserNotifications

public enum AppNavigationItem: String, CaseIterable, Identifiable {
    case messages = "Messages"
    case calls = "Calls"
    case contacts = "Contacts"
    case apps = "Apps"
    case settings = "Settings"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .messages: return "message.fill"
        case .calls: return "phone.fill"
        case .contacts: return "person.2.fill"
        case .apps: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
public final class AppState: ObservableObject, ConnectionManagerDelegate {
    @Published public var selectedNavigation: AppNavigationItem = .messages
    @Published public var activeTransport: ActiveTransport = .none
    @Published public var pairedDevice: PairedDevice?
    @Published public var deviceStatus: DeviceStatusPayload?

    // Contacts State
    @Published public var contacts: [ContactItem] = []

    // Apps State
    @Published public var apps: [InstalledApp] = []

    // Notifications State
    @Published public var notifications: [AppNotification] = []
    @Published public var unreadNotificationCount: Int = 0
    @Published public var activeMediaNotification: AppNotification? = nil
    @Published public var isAudioHandoffActive: Bool = false

    @Published public var messageError: String?
    @Published public var messagingAppReplies: [String: Bool] = [:]
    @Published public var imagePreviews: [String: Data] = [:]
    @Published public var imageErrors: [String: String] = [:]
    private var requestedImages: Set<String> = []
    private var previewOrder: [String] = []
    private func cacheImage(_ data: Data, key: String) {
        previewOrder.removeAll { $0 == key }
        previewOrder.append(key)
        imagePreviews[key] = data
        while previewOrder.count > 32 {
            let removed = previewOrder.removeFirst()
            imagePreviews.removeValue(forKey: removed)
            requestedImages.remove(removed)
        }
    }

    public func canUseMessagingApp(threadId: String) -> Bool {
        activeTransport != .none && messagingAppReplies[threadId] == true
    }

    public func refreshMessageCapabilities(threadId: String, recipient: String) {
        guard let data = try? JSONEncoder().encode(["threadId": threadId, "recipient": recipient]),
              let json = String(data: data, encoding: .utf8) else { return }
        connectionManager.sendEnvelope(MessageEnvelope(type: .chatCapabilities, payload: json))
    }

    private func outgoingImageFile(_ key: String) -> URL? {
        guard key.hasPrefix("outgoing:"), let id = UUID(uuidString: String(key.dropFirst(9))) else { return nil }
        let dir = cacheDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.uuidString + ".jpg")
    }

    public func requestImage(_ url: String) {
        if url.hasPrefix("outgoing:"), imagePreviews[url] == nil {
            if let file = outgoingImageFile(url), let data = try? Data(contentsOf: file) { cacheImage(data, key: url) }
            else { imageErrors[url] = "This image is no longer available on this Mac." }
            return
        }
        guard imagePreviews[url] == nil, requestedImages.insert(url).inserted else { return }
        guard let data = try? JSONEncoder().encode(["url": url]), let json = String(data: data, encoding: .utf8) else { return }
        connectionManager.sendEnvelope(MessageEnvelope(type: .attachmentRequest, payload: json)) { [weak self] success in
            if !success { Task { @MainActor in
                self?.requestedImages.remove(url)
                self?.imageErrors[url] = "Reconnect your phone to load this image."
            } }
        }
    }

    public func retryImage(_ url: String) {
        requestedImages.remove(url)
        imageErrors.removeValue(forKey: url)
        requestImage(url)
    }

    // Messages State
    @Published public var threads: [ChatThread] = []
    @Published public var selectedThreadId: String? {
        didSet {
            activeMessageLimit = 100
            updateActiveThreadMessages()
            if let id = selectedThreadId { markThreadAsRead(threadId: id) }
        }
    }
    @Published public var activeThreadMessages: [ChatMessage] = []
    @Published public var activeThreadTotalCount: Int = 0
    @Published public var totalUnreadMessages: Int = 0

    // High-performance non-published message storage
    private var messageStore: [String: [ChatMessage]] = [:]
    private var messageIdMap: [String: Set<String>] = [:]
    private var activeMessageLimit: Int = 100
    private var bulkMessageBuffer: [ChatMessage] = []
    private var bulkProcessTask: Task<Void, Never>?
    private var bulkTaskId = UUID()
    private var messageRevision: UInt64 = 0
    private var cacheGeneration = UUID()

    public var selectedThread: ChatThread? {
        guard let id = selectedThreadId else { return nil }
        return threads.first { $0.id == id }
    }

    public func updateActiveThreadMessages() {
        guard let id = selectedThreadId else {
            activeThreadMessages = []
            activeThreadTotalCount = 0
            return
        }
        let all = messageStore[id] ?? []
        activeThreadTotalCount = all.count
        activeThreadMessages = Array(all.suffix(activeMessageLimit))
    }

    public func loadEarlierMessages(count: Int = 150) {
        activeMessageLimit += count
        updateActiveThreadMessages()
    }

    // Calls State
    @Published public var callError: String?
    @Published public var bluetoothSetupMessage: String?
    @Published public var isCallAudioConnected = false
    @Published public var activeCall: PhoneCall?
    @Published public var incomingCall: PhoneCall?
    @Published public var callHistory: [PhoneCall] = []
    @Published public var isBluetoothHandsetPaired: Bool = false

    private var wantsMacCallAudio = false
    private var callDurationTimer: Timer?
    private let connectionManager = ConnectionManager.shared
    private let audioManager = CallAudioManager.shared

    public var connectedIp: String? {
        connectionManager.connectedIp
    }

    private var persistsCache = true

    public init(startServices: Bool = true) {
        guard startServices else { persistsCache = false; return }
        self.connectionManager.delegate = self
        self.pairedDevice = connectionManager.currentPairedDevice
        self.activeTransport = connectionManager.activeTransport
        self.selectedNavigation = (self.pairedDevice == nil) ? .settings : .messages

        loadCachedData()
        connectionManager.startServices()

        // Auto-connect Bluetooth audio gateway to paired phone
        if let phoneName = pairedDevice?.name {
            audioManager.autoConnectBluetooth(deviceName: phoneName)
        }
        checkBluetoothHandsetStatus()
        NotificationCenter.default.addObserver(forName: .init("BluetoothCallAudioChanged"), object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in self?.checkBluetoothHandsetStatus() }
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name("AudioHandoffChanged"), object: nil, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.isAudioHandoffActive = ScrcpyManager.shared.isAudioHandoffActive
            }
        }
    }

    // MARK: - Media Controls & Audio Handoff
    public func toggleAudioHandoff() {
        ScrcpyManager.shared.toggleAudioHandoff(phoneIp: connectedIp) { [weak self] success, msg in
            Task { @MainActor in
                self?.isAudioHandoffActive = ScrcpyManager.shared.isAudioHandoffActive
            }
        }
    }

    public func sendMediaCommand(_ action: String) {
        let payload: [String: String] = ["action": action]
        if let json = try? JSONEncoder().encode(payload),
           let str = String(data: json, encoding: .utf8) {
            let env = MessageEnvelope(type: .mediaControl, payload: str)
            connectionManager.sendEnvelope(env)
        }
    }

    public func updateActiveMediaNotification() {
        let found = notifications.first { notif in
            notif.isMediaPlayback == true
        }
        self.activeMediaNotification = found
    }

    public func requestNotificationPermissionsIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[Notifications] Skipping UNUserNotificationCenter because running without app bundle.")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable granted, error in
            print("[Notifications] Authorization granted: \(granted), error: \(String(describing: error))")
        }
    }

    // MARK: - ConnectionManagerDelegate
    public nonisolated func connectionManager(didReceiveEnvelope envelope: MessageEnvelope) {
        Task { @MainActor in
            self.handleInboundEnvelope(envelope)
        }
    }

    public nonisolated func connectionManager(didUpdateTransport transport: ActiveTransport) {
        Task { @MainActor in
            self.activeTransport = transport
        }
    }

    public nonisolated func connectionManager(didCompletePairing device: PairedDevice) {
        Task { @MainActor in
            self.pairedDevice = device
            self.selectedNavigation = .messages
        }
    }

    // MARK: - Inbound Handlers
    private func handleInboundEnvelope(_ envelope: MessageEnvelope) {
        let decoder = JSONDecoder()

        switch envelope.type {
        case .chatMessage:
            if let data = envelope.payload.data(using: .utf8),
               let msg = try? decoder.decode(ChatMessage.self, from: data) {
                receiveChatMessage(msg)
            }

        case .chatSync:
            if let data = envelope.payload.data(using: .utf8),
               let messages = try? decoder.decode([ChatMessage].self, from: data) {
                receiveBulkChatMessages(messages)
            }

        case .chatCapabilities:
            if let data = envelope.payload.data(using: .utf8), let response = try? decoder.decode([String: String].self, from: data),
               let threadId = response["threadId"] { messagingAppReplies[threadId] = response["canReply"] == "true" }

        case .attachmentData:
            if let data = envelope.payload.data(using: .utf8), let response = try? decoder.decode([String: String].self, from: data),
               let url = response["url"] {
                if let encoded = response["data"], encoded.count <= 4_000_004,
                   let image = Data(base64Encoded: encoded), image.count <= 3_000_000 {
                    cacheImage(image, key: url)
                    imageErrors.removeValue(forKey: url)
                } else { imageErrors[url] = response["error"] ?? "Image unavailable" }
            }

        case .chatStatusUpdate:
            if let data = envelope.payload.data(using: .utf8),
               let update = try? decoder.decode([String: String].self, from: data),
               let msgId = update["id"],
               let statusStr = update["status"],
               let status = MessageDeliveryStatus(rawValue: statusStr) {
                if let error = update["error"] { messageError = error }
                updateMessageStatus(id: msgId, status: status, messageType: update["protocol"].flatMap(MessageProtocolType.init(rawValue:)))
            }

        case .callIncoming:
            if let data = envelope.payload.data(using: .utf8),
               let call = try? decoder.decode(PhoneCall.self, from: data) {
                receiveIncomingCall(call)
            }

        case .callStateUpdate:
            if let data = envelope.payload.data(using: .utf8),
               let call = try? decoder.decode(PhoneCall.self, from: data) {
                handleCallStateUpdate(call)
            }

        case .callSync:
            if let data = envelope.payload.data(using: .utf8),
               let calls = try? decoder.decode([PhoneCall].self, from: data) {
                receiveCallSync(calls)
            }

        case .callActionResult:
            if let data = envelope.payload.data(using: .utf8),
               let result = try? decoder.decode([String: String].self, from: data), result["success"] != "true" {
                callError = result["error"] ?? "The phone could not perform the call command."
                if result["action"] == "dial", activeCall?.id == result["callId"], activeCall?.state == .dialing {
                    activeCall = nil
                    wantsMacCallAudio = false
                }
            }

        case .bluetoothPairResponse:
            if let data = envelope.payload.data(using: .utf8),
               let response = try? decoder.decode([String: String].self, from: data) {
                bluetoothSetupMessage = response["message"]
            }

        case .deviceStatus:
            if let data = envelope.payload.data(using: .utf8),
               let status = try? decoder.decode(DeviceStatusPayload.self, from: data) {
                self.deviceStatus = status
            }

        case .contactSync:
            if let data = envelope.payload.data(using: .utf8),
               let items = try? decoder.decode([ContactItem].self, from: data) {
                receiveContactSync(items)
            }

        case .appSync:
            if let data = envelope.payload.data(using: .utf8),
               let items = try? decoder.decode([InstalledApp].self, from: data) {
                receiveAppSync(items)
            }

        case .notificationSync:
            if let data = envelope.payload.data(using: .utf8),
               let items = try? decoder.decode([AppNotification].self, from: data) {
                receiveNotificationSync(items)
            }

        case .notificationPosted:
            if let data = envelope.payload.data(using: .utf8),
               let item = try? decoder.decode(AppNotification.self, from: data) {
                receiveNotificationPosted(item)
            }

        case .notificationRemoved:
            messagingAppReplies.removeAll()
            if let data = envelope.payload.data(using: .utf8),
               let dict = try? decoder.decode([String: String].self, from: data),
               let notifId = dict["id"] {
                receiveNotificationRemoved(id: notifId)
            }

        default:
            break
        }
    }

    // MARK: - Notifications Actions
    public func receiveNotificationSync(_ syncedNotifications: [AppNotification]) {
        self.notifications = syncedNotifications.filter { notif in
            !Self.isSystemNoise(threadId: notif.appName, text: notif.text) &&
            !Self.isSystemNoise(threadId: notif.appName, text: notif.title)
        }.sorted { $0.timestamp > $1.timestamp }
        self.unreadNotificationCount = self.notifications.count
        self.updateActiveMediaNotification()
        saveCachedData()
    }

    public func receiveNotificationPosted(_ notification: AppNotification) {
        if Self.isSystemNoise(threadId: notification.appName, text: notification.text) ||
           Self.isSystemNoise(threadId: notification.appName, text: notification.title) {
            return
        }
        self.notifications.removeAll { $0.id == notification.id }
        self.notifications.insert(notification, at: 0)
        self.unreadNotificationCount = self.notifications.count
        self.updateActiveMediaNotification()
        saveCachedData()

        // Route to macOS notification toast while the Mac is "Online"
        if activeTransport != .none {
            postMacNotificationToast(for: notification)
        }
    }

    public func receiveNotificationRemoved(id: String) {
        self.notifications.removeAll { $0.id == id }
        self.unreadNotificationCount = self.notifications.count
        self.updateActiveMediaNotification()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
        saveCachedData()
    }

    public func dismissNotification(_ notification: AppNotification) {
        // 1. Tell Android companion to cancel notification
        let payload = ["id": notification.id]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            let envelope = MessageEnvelope(type: .notificationDismiss, payload: str)
            connectionManager.sendEnvelope(envelope)
        }

        // 2. Remove locally
        self.notifications.removeAll { $0.id == notification.id }
        self.unreadNotificationCount = self.notifications.count
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification.id])
        }
        saveCachedData()
    }

    public func clearAllNotifications() {
        for n in self.notifications where n.isClearable {
            dismissNotification(n)
        }
    }

    public func postMacNotificationToast(for notification: AppNotification) {
        // 1. Try UNUserNotificationCenter if bundle ID exists
        if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = notification.appName.isEmpty ? notification.title : notification.appName
            content.subtitle = notification.title != notification.appName ? notification.title : ""
            content.body = notification.text
            content.sound = .default
            content.userInfo = ["notificationId": notification.id, "packageName": notification.packageName]

            let request = UNNotificationRequest(
                identifier: notification.id,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { @Sendable _ in }
        }

        // 2. Also trigger native macOS notification banner via osascript
        // This ensures the banner pop-up appears in macOS Notification Center unconditionally
        DispatchQueue.global(qos: .userInitiated).async {
            let cleanApp = (notification.appName.isEmpty ? "Droid Link" : notification.appName)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let cleanTitle = notification.title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let cleanText = notification.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "display notification \"\(cleanText)\" with title \"\(cleanApp)\" subtitle \"\(cleanTitle)\""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }

    public func launchNotificationApp(_ notification: AppNotification) {
        let payload = ["packageName": notification.packageName]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            let envelope = MessageEnvelope(type: .appLaunch, payload: str)
            connectionManager.sendEnvelope(envelope)
        }

        ScrcpyManager.shared.launchScrcpy(
            packageName: notification.packageName,
            appTitle: notification.appName,
            phoneIp: connectionManager.connectedIp
        )
    }

    public func refreshNotifications() {
        let envelope = MessageEnvelope(type: .notificationSync, payload: "{}")
        connectionManager.sendEnvelope(envelope)
    }

    // MARK: - Contacts Actions
    public func receiveContactSync(_ syncedContacts: [ContactItem]) {
        var map = Dictionary(uniqueKeysWithValues: self.contacts.map { ($0.id, $0) })
        for c in syncedContacts {
            map[c.id] = c
        }
        self.contacts = map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveCachedData()
    }

    // MARK: - App Actions
    public func receiveAppSync(_ syncedApps: [InstalledApp]) {
        var existingMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.packageName, $0) })
        for app in syncedApps {
            existingMap[app.packageName] = app
        }
        self.apps = Array(existingMap.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveCachedData()
    }

    public func launchApp(_ app: InstalledApp) {
        // 1. Send launch command to Android companion
        let payload = ["packageName": app.packageName]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            let envelope = MessageEnvelope(type: .appLaunch, payload: str)
            connectionManager.sendEnvelope(envelope)
        }

        // 2. Launch bundled scrcpy mirroring window for this app
        ScrcpyManager.shared.launchScrcpy(for: app, phoneIp: connectionManager.connectedIp)
    }

    public func refreshApps() {
        let envelope = MessageEnvelope(type: .appSync, payload: "{}")
        connectionManager.sendEnvelope(envelope)
    }

    public func installApk(from fileURL: URL, completion: @escaping @Sendable (Bool, String) -> Void) {
        ScrcpyManager.shared.installApk(fileURL: fileURL, completion: completion)
    }

    // MARK: - Filtering System Noise & Duplicates
    public nonisolated static func isSystemNoise(threadId: String, text: String, senderName: String = "") -> Bool {
        let tLow = threadId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sLow = senderName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let txtLow = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if tLow.contains("device pairing") || sLow.contains("device pairing") { return true }
        if (tLow == "unknown" || sLow == "unknown") && (txtLow.isEmpty || txtLow.contains("work")) { return true }
        if txtLow.contains("messages is doing work") || txtLow.contains("doing work in the background") { return true }
        if txtLow.contains("your messages are available") || txtLow.contains("pairing with") { return true }
        if txtLow.contains("chat features") || txtLow.contains("rcs chats") { return true }
        if txtLow.contains("connected to messages for web") { return true }

        return false
    }

    // Only reconcile a local outgoing placeholder with its provider record.
    // Two provider records with identical text are still separate messages.
    public nonisolated static func isMessageEcho(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        func isProvider(_ id: String) -> Bool {
            id.hasPrefix("sms_") || id.hasPrefix("mms_")
        }
        return lhs.attachments.isEmpty && rhs.attachments.isEmpty && lhs.attachmentUrl == nil && rhs.attachmentUrl == nil &&
            lhs.threadId == rhs.threadId && lhs.isFromMe && rhs.isFromMe &&
            isProvider(lhs.id) != isProvider(rhs.id) &&
            lhs.text.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.text.trimmingCharacters(in: .whitespacesAndNewlines) &&
            abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 75
    }

    public nonisolated static func deduplicateMessageList(_ list: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var seenIds = Set<String>()
        let sorted = list.sorted { $0.timestamp < $1.timestamp }
        for msg in sorted {
            // Discard any legacy synthetic notification message with pipe '|'
            if msg.id.contains("|") { continue }

            let clean = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.hasContent || isSystemNoise(threadId: msg.threadId, text: clean, senderName: msg.senderName) { continue }
            if seenIds.contains(msg.id) { continue }

            var isDup = false
            for ex in result.suffix(20) {
                if isMessageEcho(ex, msg) {
                    isDup = true
                    break
                }
            }
            if !isDup {
                seenIds.insert(msg.id)
                result.append(msg)
            } else {
                if let idx = result.indices.suffix(20).first(where: {
                    isMessageEcho(result[$0], msg)
                }) {
                    if (result[idx].id.contains("-") || result[idx].id.contains("|")) &&
                       (msg.id.hasPrefix("sms_") || msg.id.hasPrefix("mms_")) {
                        seenIds.remove(result[idx].id)
                        result[idx] = msg
                        seenIds.insert(msg.id)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Message Actions
    public func receiveBulkChatMessages(_ syncedMessages: [ChatMessage]) {
        bulkMessageBuffer.append(contentsOf: syncedMessages)
        guard bulkProcessTask == nil else { return }
        let taskId = UUID()
        bulkTaskId = taskId
        bulkProcessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            defer { if self.bulkTaskId == taskId { self.bulkProcessTask = nil } }
            while !self.bulkMessageBuffer.isEmpty && !Task.isCancelled {
                let revision = self.messageRevision
                let incoming = self.bulkMessageBuffer
                self.bulkMessageBuffer.removeAll()
                let currentStore = self.messageStore
                let currentIdMap = self.messageIdMap
                let currentThreads = self.threads
                let result = await Task.detached(priority: .userInitiated) { () -> ([String: [ChatMessage]], [String: Set<String>], [ChatThread]) in
                    var store = currentStore
                    var idMap = currentIdMap
                    var threads = currentThreads

                    var incomingByThread: [String: [ChatMessage]] = [:]
                    for m in incoming {
                        incomingByThread[m.threadId, default: []].append(m)
                    }

                    for (threadId, newMsgs) in incomingByThread {
                        if Self.isSystemNoise(threadId: threadId, text: newMsgs.first?.text ?? "", senderName: newMsgs.first?.senderName ?? "") {
                            continue
                        }
                        var existingList = store[threadId] ?? []
                        var ids = idMap[threadId] ?? Set(existingList.map { $0.id })
                        var indicesById = Dictionary(existingList.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })

                        for msg in newMsgs {
                            let cleanText = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !msg.hasContent || Self.isSystemNoise(threadId: msg.threadId, text: cleanText, senderName: msg.senderName) {
                                continue
                            }

                            if ids.contains(msg.id) {
                                if let idx = indicesById[msg.id] {
                                    existingList[idx] = msg
                                }
                                continue
                            }

                            // Window-based fuzzy deduplication (same direction, same text, within 75s)
                            var isDuplicate = false
                            for existing in existingList.suffix(20) {
                                if Self.isMessageEcho(existing, msg) {
                                    isDuplicate = true
                                    break
                                }
                            }

                            if isDuplicate {
                                if let idx = existingList.indices.suffix(20).first(where: {
                                    Self.isMessageEcho(existingList[$0], msg)
                                }) {
                                    if (existingList[idx].id.contains("-") || existingList[idx].id.contains("|")) &&
                                       (msg.id.hasPrefix("sms_") || msg.id.hasPrefix("mms_")) {
                                        ids.remove(existingList[idx].id)
                                        indicesById.removeValue(forKey: existingList[idx].id)
                                        indicesById[msg.id] = idx
                                        existingList[idx] = msg
                                        ids.insert(msg.id)
                                    }
                                }
                                continue
                            }

                            ids.insert(msg.id)
                            indicesById[msg.id] = existingList.count
                            existingList.append(msg)
                        }

                        existingList.sort { $0.timestamp < $1.timestamp }
                        store[threadId] = existingList
                        idMap[threadId] = ids

                        guard let latest = existingList.last else { continue }
                        let name = existingList.first(where: { !$0.isFromMe && !$0.senderName.isEmpty && $0.senderName != threadId })?.senderName ?? latest.senderName
                        let contactName = (name.isEmpty || name == "Me") ? threadId : name
                        let isRcs = existingList.contains(where: { $0.messageType == .rcs }) || latest.messageType == .rcs

                        if let idx = threads.firstIndex(where: { $0.id == threadId }) {
                            threads[idx].contactName = contactName
                            threads[idx].contactAddress = threadId.hasPrefix("notification_group_") ? latest.senderAddress : threadId
                            threads[idx].lastMessage = latest.text.isEmpty && latest.hasContent ? "Image" : latest.text
                            threads[idx].lastMessageDate = latest.timestamp
                            threads[idx].isRcs = isRcs
                        } else {
                            threads.append(ChatThread(
                                id: threadId,
                                contactName: contactName,
                                contactAddress: threadId.hasPrefix("notification_group_") ? latest.senderAddress : threadId,
                                lastMessage: latest.text.isEmpty && latest.hasContent ? "Image" : latest.text,
                                lastMessageDate: latest.timestamp,
                                unreadCount: 0,
                                isRcs: isRcs
                            ))
                        }
                    }

                    threads.sort { $0.lastMessageDate > $1.lastMessageDate }
                    return (store, idMap, threads)
                }.value
                guard !Task.isCancelled else { return }
                // Live messages/statuses may arrive while the background merge is running.
                if self.messageRevision != revision {
                    self.bulkMessageBuffer.insert(contentsOf: incoming, at: 0)
                    continue
                }
                self.messageRevision &+= 1
                self.messageStore = result.0
                self.messageIdMap = result.1
                self.threads = result.2
                if self.selectedThreadId == nil { self.selectedThreadId = self.threads.first?.id }
                self.updateActiveThreadMessages()
                self.recalculateUnreadCount()
                self.saveCachedData()
            }
        }
    }

    public func receiveChatMessage(_ msg: ChatMessage) {
        messageRevision &+= 1
        if msg.id.contains("|") { return }

        let clean = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.hasContent || Self.isSystemNoise(threadId: msg.threadId, text: clean, senderName: msg.senderName) {
            return
        }

        // Resolve target thread: either exact id, or match by contactName / address
        var targetThreadId = msg.threadId
        if let matched = threads.first(where: {
            $0.id == msg.threadId ||
            $0.contactAddress == msg.threadId
        }) {
            targetThreadId = matched.id
        } else if msg.id.hasPrefix("notification_image_") && !msg.threadId.hasPrefix("notification_group_") {
            let matching = threads.filter { $0.contactName.caseInsensitiveCompare(msg.senderName) == .orderedSame }
            if matching.count == 1 { targetThreadId = matching[0].id }
        }

        if messageStore[targetThreadId] == nil {
            messageStore[targetThreadId] = []
            messageIdMap[targetThreadId] = []
        }

        // Deduplicate against notification repeats & background sync duplicates
        if messageIdMap[targetThreadId]?.contains(msg.id) == true {
            return
        }
        if let existing = messageStore[targetThreadId]?.suffix(20).first(where: {
            $0.id == msg.id ||
            Self.isMessageEcho($0, msg)
        }) {
            if let existingIdx = messageStore[targetThreadId]?.indices.suffix(20).first(where: {
                messageStore[targetThreadId]![$0].id == existing.id
            }) {
                if (existing.id.contains("-") || existing.id.contains("|")) &&
                   (msg.id.hasPrefix("sms_") || msg.id.hasPrefix("mms_")) {
                    messageIdMap[targetThreadId]?.remove(existing.id)
                    messageStore[targetThreadId]![existingIdx] = msg
                    messageIdMap[targetThreadId]?.insert(msg.id)
                    if selectedThreadId == targetThreadId { updateActiveThreadMessages() }
                    saveCachedData()
                }
            }
            return
        }

        messageIdMap[targetThreadId]?.insert(msg.id)
        messageStore[targetThreadId]?.append(msg)
        messageStore[targetThreadId]?.sort { $0.timestamp < $1.timestamp }

        if let idx = threads.firstIndex(where: { $0.id == targetThreadId }) {
            threads[idx].lastMessage = msg.text
            threads[idx].lastMessageDate = msg.timestamp
            if !msg.isFromMe && selectedThreadId != targetThreadId {
                threads[idx].unreadCount += 1
            }
        } else {
            let newThread = ChatThread(
                id: targetThreadId,
                contactName: msg.senderName.isEmpty ? msg.senderAddress : msg.senderName,
                contactAddress: msg.senderAddress,
                lastMessage: msg.text,
                lastMessageDate: msg.timestamp,
                unreadCount: msg.isFromMe || selectedThreadId == targetThreadId ? 0 : 1,
                isRcs: msg.messageType == .rcs
            )
            threads.insert(newThread, at: 0)
        }

        if selectedThreadId == targetThreadId {
            updateActiveThreadMessages()
        }

        threads.sort { $0.lastMessageDate > $1.lastMessageDate }
        recalculateUnreadCount()
        saveCachedData()
    }

    public func sendMessage(to recipient: String, text: String, threadId: String, isRcs: Bool = true, imageData: Data? = nil) {
        messageRevision &+= 1
        let isRcs = isRcs && canUseMessagingApp(threadId: threadId)
        if threadId.hasPrefix("notification_group_") && !isRcs && imageData == nil {
            messageError = "This group needs an active reply notification on the phone. SMS fallback cannot address an RCS group."
            return
        }
        let msg = ChatMessage(
            threadId: threadId,
            senderName: "Me",
            senderAddress: "Me",
            isFromMe: true,
            text: text,
            timestamp: Date(),
            status: .sending,
            messageType: imageData != nil || isRcs ? .unknown : .sms,
            attachments: imageData.map { _ in [MessageAttachment(url: "outgoing:" + UUID().uuidString, mimeType: "image/jpeg")] } ?? []
        )

        if let imageData, let url = msg.attachments.first?.url {
            cacheImage(imageData, key: url)
            if let file = outgoingImageFile(url) { try? imageData.write(to: file, options: .atomic) }
        }
        if messageStore[threadId] == nil {
            messageStore[threadId] = []
            messageIdMap[threadId] = []
        }
        messageIdMap[threadId]?.insert(msg.id)
        messageStore[threadId]?.append(msg)

        if let idx = threads.firstIndex(where: { $0.id == threadId }) {
            threads[idx].lastMessage = text.isEmpty && imageData != nil ? "Image" : text
            threads[idx].lastMessageDate = Date()
        } else {
            threads.append(ChatThread(id: threadId, contactName: recipient, contactAddress: recipient,
                lastMessage: text.isEmpty && imageData != nil ? "Image" : text, lastMessageDate: Date(), unreadCount: 0, isRcs: false))
        }
        threads.sort { $0.lastMessageDate > $1.lastMessageDate }
        saveCachedData()

        if selectedThreadId == threadId {
            updateActiveThreadMessages()
        }

        var req = OutgoingMessageRequest(
            id: msg.id,
            threadId: threadId,
            recipient: recipient,
            text: text,
            preferRcs: isRcs
        )

        req.imageBase64 = imageData?.base64EncodedString()

        if let enc = try? JSONEncoder().encode(req),
           let jsonStr = String(data: enc, encoding: .utf8) {
            let envelope = MessageEnvelope(type: .chatSend, payload: jsonStr)
            connectionManager.sendEnvelope(envelope) { success in
                Task { @MainActor in
                    if !success { self.updateMessageStatus(id: msg.id, status: .failed) }
                }
            }
        }
    }

    public func retryMessageAsSms(_ message: ChatMessage) {
        guard message.isFromMe, message.status == .failed else { return }
        let address = threads.first { $0.id == message.threadId }?.contactAddress ?? message.threadId
        sendMessage(to: address, text: message.text, threadId: message.threadId, isRcs: false)
    }

    public func updateMessageStatus(id: String, status: MessageDeliveryStatus, messageType: MessageProtocolType? = nil) {
        messageRevision &+= 1
        for (threadId, msgs) in messageStore {
            if let idx = msgs.firstIndex(where: { $0.id == id }) {
                if msgs[idx].status.canTransition(to: status) {
                    messageStore[threadId]?[idx].status = status
                }
                if let messageType { messageStore[threadId]?[idx].messageType = messageType }
                if selectedThreadId == threadId {
                    updateActiveThreadMessages()
                }
                saveCachedData()
                break
            }
        }
    }

    public func markThreadAsRead(threadId: String) {
        messageRevision &+= 1
        if let idx = threads.firstIndex(where: { $0.id == threadId }) {
            threads[idx].unreadCount = 0
            recalculateUnreadCount()
            saveCachedData()
        }
    }

    private func recalculateUnreadCount() {
        totalUnreadMessages = threads.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Call Actions
    public func receiveIncomingCall(_ call: PhoneCall) {
        self.incomingCall = call
    }

    private func sendCallAction(_ payload: CallActionPayload) {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: json)) { [weak self] success in
            if !success {
                Task { @MainActor in
                    self?.callError = "The phone is disconnected. The call command was not sent."
                    if payload.action == .dial, self?.activeCall?.id == payload.callId {
                        self?.activeCall = nil
                        self?.wantsMacCallAudio = false
                    }
                }
            }
        }
    }

    public func answerIncomingCall() {
        guard let call = incomingCall else { return }
        wantsMacCallAudio = true
        sendCallAction(CallActionPayload(callId: call.id, action: .answer))
    }

    public func declineIncomingCall() {
        guard let call = incomingCall else { return }
        sendCallAction(CallActionPayload(callId: call.id, action: .reject))
    }

    public func dialCall(number: String, contactName: String = "") {
        let number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        guard activeCall == nil && incomingCall == nil else {
            callError = "End the current call before starting another call."
            return
        }
        let call = PhoneCall(phoneNumber: number, contactName: contactName, state: .dialing, direction: .outgoing)
        activeCall = call
        wantsMacCallAudio = true
        // Dial only through the companion. HFP is used for audio, not a second dial command.
        sendCallAction(CallActionPayload(callId: call.id, action: .dial, number: number))
    }

    public func hangupCall() {
        guard let call = activeCall else { return }
        sendCallAction(CallActionPayload(callId: call.id, action: .hangup))
    }

    public func toggleMute() {
        guard let call = activeCall else { return }
        sendCallAction(CallActionPayload(callId: call.id, action: call.isMuted ? .unmute : .mute))
    }

    public func selectCallAudio(_ action: CallActionType) {
        guard let call = activeCall else { return }
        if action == .audioBluetooth {
            wantsMacCallAudio = true
            audioManager.autoConnectBluetooth(deviceName: pairedDevice?.name)
            audioManager.startCallAudioRouting()
        } else {
            wantsMacCallAudio = false
            audioManager.stopCallAudioRouting()
        }
        sendCallAction(CallActionPayload(callId: call.id, action: action))
    }

    public func sendDtmf(digit: Character) {
        audioManager.playDtmfTone(digit: digit)
        guard let call = activeCall else { return }

        let payload = CallActionPayload(callId: call.id, action: .dtmf, dtmfDigit: String(digit))
        if let enc = try? JSONEncoder().encode(payload),
           let str = String(data: enc, encoding: .utf8) {
            connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: str))
        }
    }

    private func handleCallStateUpdate(_ updatedCall: PhoneCall) {
        if updatedCall.state == .ended || updatedCall.state == .missed || updatedCall.state == .rejected {
            if activeCall?.id == updatedCall.id {
                activeCall = nil
                callDurationTimer?.invalidate()
                callDurationTimer = nil
                audioManager.stopCallAudioRouting()
                wantsMacCallAudio = false
            }
            if incomingCall?.id == updatedCall.id { incomingCall = nil }
            callHistory.removeAll { $0.id == updatedCall.id }
            callHistory.insert(updatedCall, at: 0)
            saveCachedData()
        } else if updatedCall.state == .active || updatedCall.state == .held || updatedCall.state == .dialing || updatedCall.state == .ringing {
            if incomingCall?.id == updatedCall.id { incomingCall = nil }
            if updatedCall.state == .held && activeCall?.id != updatedCall.id && activeCall?.state == .active { return }
            let wasActive = activeCall?.id == updatedCall.id && activeCall?.state == .active
            activeCall = updatedCall
            if updatedCall.state == .active {
                startDurationTimer()
                if !wasActive && wantsMacCallAudio { audioManager.startCallAudioRouting() }
            } else {
                callDurationTimer?.invalidate()
                callDurationTimer = nil
            }
        }
        checkBluetoothHandsetStatus()
    }

    public func receiveCallSync(_ syncedCalls: [PhoneCall]) {
        var existingMap = Dictionary(callHistory.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for call in syncedCalls {
            existingMap[call.id] = call
        }
        self.callHistory = existingMap.values.sorted {
            ($0.startTime ?? Date.distantPast) > ($1.startTime ?? Date.distantPast)
        }
        saveCachedData()
    }

    private func startDurationTimer() {
        callDurationTimer?.invalidate()
        callDurationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, var call = self.activeCall else { return }
                call.duration = call.startTime.map { max(0, Date().timeIntervalSince($0)) } ?? (call.duration + 1)
                self.activeCall = call
            }
        }
    }

    public func checkBluetoothHandsetStatus() {
        isBluetoothHandsetPaired = audioManager.isBluetoothHandsetAvailable(deviceName: pairedDevice?.name)
        isCallAudioConnected = audioManager.isCallAudioConnected
    }

    public func initiateBluetoothPairing() {
        let macName = Host.current().localizedName ?? "Mac"
        var payloadDict = ["name": macName]
        if let controller = IOBluetoothHostController.default() {
            payloadDict["address"] = controller.addressAsString() ?? ""
        }
        let jsonStr = (try? String(data: JSONEncoder().encode(payloadDict), encoding: .utf8)) ?? "pair"
        let envelope = MessageEnvelope(type: .bluetoothPairRequest, payload: jsonStr)
        connectionManager.sendEnvelope(envelope)

        audioManager.autoConnectBluetooth(deviceName: pairedDevice?.name)

        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    public func unpairCurrentDevice() {
        cacheGeneration = UUID()
        messageRevision &+= 1
        bulkProcessTask?.cancel()
        bulkProcessTask = nil
        bulkTaskId = UUID()
        bulkMessageBuffer.removeAll()
        saveCacheTask?.cancel()
        audioManager.disconnectPhone()
        wantsMacCallAudio = false
        activeCall = nil
        incomingCall = nil
        callDurationTimer?.invalidate()
        callDurationTimer = nil
        checkBluetoothHandsetStatus()
        connectionManager.unpairDevice()
        pairedDevice = nil
        threads = []
        contacts = []
        apps = []
        imagePreviews = [:]
        previewOrder = []
        imageErrors = [:]
        requestedImages = []
        messagingAppReplies = [:]
        messageStore = [:]
        messageIdMap = [:]
        activeThreadMessages = []
        activeThreadTotalCount = 0
        callHistory = []
        selectedThreadId = nil
        clearCachedData()
        selectedNavigation = .settings
    }

    // MARK: - Local Cache Persistence
    private var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DroidLink/cache", isDirectory: true)
        let legacyDir = appSupport.appendingPathComponent("DroidDock/cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) && FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadCachedData() {
        let decoder = JSONDecoder()
        let tUrl = cacheDirectory.appendingPathComponent("threads.json")
        let cUrl = cacheDirectory.appendingPathComponent("calls.json")
        let ctUrl = cacheDirectory.appendingPathComponent("contacts.json")
        let aUrl = cacheDirectory.appendingPathComponent("apps.json")
        let nUrl = cacheDirectory.appendingPathComponent("notifications.json")
        let mUrl = cacheDirectory.appendingPathComponent("messages.json")

        // 1. Fast load threads, calls, contacts, apps & notifications immediately for instant 0ms window display
        if let tData = try? Data(contentsOf: tUrl),
           let savedThreads = try? decoder.decode([ChatThread].self, from: tData) {
            self.threads = savedThreads.filter {
                !Self.isSystemNoise(threadId: $0.id, text: $0.lastMessage, senderName: $0.contactName) &&
                !Self.isSystemNoise(threadId: $0.contactAddress, text: $0.lastMessage, senderName: $0.contactName)
            }
            self.selectedThreadId = self.threads.first?.id
        }

        if let cData = try? Data(contentsOf: cUrl),
           let savedCalls = try? decoder.decode([PhoneCall].self, from: cData) {
            self.callHistory = savedCalls
        }

        if let ctData = try? Data(contentsOf: ctUrl),
           let savedContacts = try? decoder.decode([ContactItem].self, from: ctData) {
            self.contacts = savedContacts
        }

        if let aData = try? Data(contentsOf: aUrl),
           let savedApps = try? decoder.decode([InstalledApp].self, from: aData) {
            self.apps = savedApps
        }

        if let nData = try? Data(contentsOf: nUrl),
           let savedNotifs = try? decoder.decode([AppNotification].self, from: nData) {
            self.notifications = savedNotifs.filter { !Self.isSystemNoise(threadId: $0.appName, text: $0.title) && !Self.isSystemNoise(threadId: $0.appName, text: $0.text) }
            self.unreadNotificationCount = self.notifications.count
            self.updateActiveMediaNotification()
        }
        recalculateUnreadCount()

        // 2. Offload large 12,000+ message cache parsing, filtering phantom threads, deduplication, and id indexing completely to background
        let generation = cacheGeneration
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([String: [ChatMessage]], [String: Set<String>])? in
                guard let mData = try? Data(contentsOf: mUrl),
                      let rawMsgs = try? JSONDecoder().decode([String: [ChatMessage]].self, from: mData) else { return nil }
                var msgs: [String: [ChatMessage]] = [:]
                var idMap: [String: Set<String>] = [:]
                for (tId, list) in rawMsgs {
                    if Self.isSystemNoise(threadId: tId, text: list.last?.text ?? "", senderName: list.last?.senderName ?? "") {
                        continue
                    }
                    let deduped = Self.deduplicateMessageList(list)
                    msgs[tId] = deduped
                    idMap[tId] = Set(deduped.map { $0.id })
                }
                return (msgs, idMap)
            }.value

            if let (msgs, _) = result {
                await MainActor.run { [weak self] in
                    guard let self = self, self.cacheGeneration == generation else { return }
                    self.messageRevision &+= 1
                    for (threadId, cached) in msgs {
                        var merged = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                        for live in self.messageStore[threadId] ?? [] { merged[live.id] = live }
                        let messages = Self.deduplicateMessageList(Array(merged.values))
                        self.messageStore[threadId] = messages
                        self.messageIdMap[threadId] = Set(messages.map(\.id))
                    }
                    self.updateActiveThreadMessages()
                    self.recalculateUnreadCount()
                    self.saveCachedData()
                }
            }
        }
    }

    private var saveCacheTask: Task<Void, Never>?

    private func saveCachedData() {
        guard persistsCache else { return }
        saveCacheTask?.cancel()
        saveCacheTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s debounce to avoid copying during typing/sending
            guard !Task.isCancelled, let self = self else { return }

            let tCopy = self.threads
            let mCopy = self.messageStore
            let cCopy = self.callHistory
            let ctCopy = self.contacts
            let aCopy = self.apps
            let nCopy = self.notifications
            let cacheDir = self.cacheDirectory

            Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                let tUrl = cacheDir.appendingPathComponent("threads.json")
                let mUrl = cacheDir.appendingPathComponent("messages.json")
                let cUrl = cacheDir.appendingPathComponent("calls.json")
                let ctUrl = cacheDir.appendingPathComponent("contacts.json")
                let aUrl = cacheDir.appendingPathComponent("apps.json")
                let nUrl = cacheDir.appendingPathComponent("notifications.json")

                if let tData = try? encoder.encode(tCopy) {
                    try? tData.write(to: tUrl, options: .atomic)
                }
                guard !Task.isCancelled else { return }
                if let mData = try? encoder.encode(mCopy) {
                    try? mData.write(to: mUrl, options: .atomic)
                }
                guard !Task.isCancelled else { return }
                if let cData = try? encoder.encode(cCopy) {
                    try? cData.write(to: cUrl, options: .atomic)
                }
                guard !Task.isCancelled else { return }
                if let ctData = try? encoder.encode(ctCopy) {
                    try? ctData.write(to: ctUrl, options: .atomic)
                }
                guard !Task.isCancelled else { return }
                if let aData = try? encoder.encode(aCopy) {
                    try? aData.write(to: aUrl, options: .atomic)
                }
                guard !Task.isCancelled else { return }
                if let nData = try? encoder.encode(nCopy) {
                    try? nData.write(to: nUrl, options: .atomic)
                }
            }
        }
    }

    private func clearCachedData() {
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("images"))
        let tUrl = cacheDirectory.appendingPathComponent("threads.json")
        let mUrl = cacheDirectory.appendingPathComponent("messages.json")
        let cUrl = cacheDirectory.appendingPathComponent("calls.json")
        let ctUrl = cacheDirectory.appendingPathComponent("contacts.json")
        let aUrl = cacheDirectory.appendingPathComponent("apps.json")
        let nUrl = cacheDirectory.appendingPathComponent("notifications.json")
        try? FileManager.default.removeItem(at: tUrl)
        try? FileManager.default.removeItem(at: mUrl)
        try? FileManager.default.removeItem(at: cUrl)
        try? FileManager.default.removeItem(at: ctUrl)
        try? FileManager.default.removeItem(at: aUrl)
        try? FileManager.default.removeItem(at: nUrl)
    }
}
