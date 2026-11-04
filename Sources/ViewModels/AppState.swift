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

    // Messages State
    @Published public var threads: [ChatThread] = []
    @Published public var selectedThreadId: String? {
        didSet {
            updateActiveThreadMessages()
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
    @Published public var activeCall: PhoneCall?
    @Published public var incomingCall: PhoneCall?
    @Published public var callHistory: [PhoneCall] = []
    @Published public var isBluetoothHandsetPaired: Bool = false

    private var callDurationTimer: Timer?
    private let connectionManager = ConnectionManager.shared
    private let audioManager = CallAudioManager.shared

    public var connectedIp: String? {
        connectionManager.connectedIp
    }

    public init() {
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

        case .chatStatusUpdate:
            if let data = envelope.payload.data(using: .utf8),
               let update = try? decoder.decode([String: String].self, from: data),
               let msgId = update["id"],
               let statusStr = update["status"],
               let status = MessageDeliveryStatus(rawValue: statusStr) {
                updateMessageStatus(id: msgId, status: status)
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
        self.notifications = syncedNotifications.sorted { $0.timestamp > $1.timestamp }
        self.unreadNotificationCount = self.notifications.count
        saveCachedData()
    }

    public func receiveNotificationPosted(_ notification: AppNotification) {
        self.notifications.removeAll { $0.id == notification.id }
        self.notifications.insert(notification, at: 0)
        self.unreadNotificationCount = self.notifications.count
        saveCachedData()

        // Route to macOS notification toast while the Mac is "Online"
        if activeTransport != .none {
            postMacNotificationToast(for: notification)
        }
    }

    public func receiveNotificationRemoved(id: String) {
        self.notifications.removeAll { $0.id == id }
        self.unreadNotificationCount = self.notifications.count
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

    // MARK: - Message Actions
    public func receiveBulkChatMessages(_ syncedMessages: [ChatMessage]) {
        bulkMessageBuffer.append(contentsOf: syncedMessages)
        bulkProcessTask?.cancel()
        bulkProcessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms batch buffer
            guard !Task.isCancelled, let self = self else { return }

            let incoming = await MainActor.run { () -> [ChatMessage] in
                let msgs = self.bulkMessageBuffer
                self.bulkMessageBuffer.removeAll()
                return msgs
            }

            guard !incoming.isEmpty else { return }

            let (currentStore, currentIdMap, currentThreads) = await MainActor.run {
                (self.messageStore, self.messageIdMap, self.threads)
            }

            // 100% offloaded to background thread with O(1) deduplication: ZERO main-thread freeze
            let result = await Task.detached(priority: .userInitiated) { () -> ([String: [ChatMessage]], [String: Set<String>], [ChatThread]) in
                var store = currentStore
                var idMap = currentIdMap
                var threads = currentThreads

                var incomingByThread: [String: [ChatMessage]] = [:]
                for m in incoming {
                    incomingByThread[m.threadId, default: []].append(m)
                }

                for (threadId, newMsgs) in incomingByThread {
                    var existingList = store[threadId] ?? []
                    var ids = idMap[threadId] ?? Set(existingList.map { $0.id })

                    for msg in newMsgs {
                        if ids.contains(msg.id) {
                            if let idx = existingList.firstIndex(where: { $0.id == msg.id }) {
                                existingList[idx] = msg
                            }
                        } else {
                            ids.insert(msg.id)
                            existingList.append(msg)
                        }
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
                        threads[idx].contactAddress = threadId
                        threads[idx].lastMessage = latest.text
                        threads[idx].lastMessageDate = latest.timestamp
                        threads[idx].isRcs = isRcs
                    } else {
                        threads.append(ChatThread(
                            id: threadId,
                            contactName: contactName,
                            contactAddress: threadId,
                            lastMessage: latest.text,
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

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.messageStore = result.0
                self.messageIdMap = result.1
                self.threads = result.2
                if self.selectedThreadId == nil {
                    self.selectedThreadId = self.threads.first?.id
                }
                self.updateActiveThreadMessages()
                self.recalculateUnreadCount()
                self.saveCachedData()
            }
        }
    }

    public func receiveChatMessage(_ msg: ChatMessage) {
        // Resolve target thread: either exact id, or match by contactName / address
        var targetThreadId = msg.threadId
        if let matched = threads.first(where: {
            $0.id == msg.threadId ||
            $0.contactAddress == msg.threadId ||
            (!msg.senderName.isEmpty && $0.contactName.lowercased() == msg.senderName.lowercased())
        }) {
            targetThreadId = matched.id
        }

        if messageStore[targetThreadId] == nil {
            messageStore[targetThreadId] = []
            messageIdMap[targetThreadId] = []
        }

        // Deduplicate against notification repeats & background sync duplicates
        if messageIdMap[targetThreadId]?.contains(msg.id) == true {
            return
        }
        if let _ = messageStore[targetThreadId]?.suffix(15).first(where: {
            $0.id == msg.id ||
            ($0.isFromMe == msg.isFromMe && $0.text.trimmingCharacters(in: .whitespaces) == msg.text.trimmingCharacters(in: .whitespaces) && abs($0.timestamp.timeIntervalSince(msg.timestamp)) < 25)
        }) {
            return
        }

        messageIdMap[targetThreadId]?.insert(msg.id)
        messageStore[targetThreadId]?.append(msg)

        if let idx = threads.firstIndex(where: { $0.id == targetThreadId }) {
            threads[idx].lastMessage = msg.text
            threads[idx].lastMessageDate = msg.timestamp
            if selectedThreadId != targetThreadId {
                threads[idx].unreadCount += 1
            }
        } else {
            let newThread = ChatThread(
                id: targetThreadId,
                contactName: msg.senderName.isEmpty ? msg.senderAddress : msg.senderName,
                contactAddress: msg.senderAddress,
                lastMessage: msg.text,
                lastMessageDate: msg.timestamp,
                unreadCount: selectedThreadId == targetThreadId ? 0 : 1,
                isRcs: msg.messageType == .rcs
            )
            threads.insert(newThread, at: 0)
        }

        if selectedThreadId == targetThreadId {
            updateActiveThreadMessages()
        }

        recalculateUnreadCount()
        saveCachedData()
    }

    public func sendMessage(to recipient: String, text: String, threadId: String, isRcs: Bool = true) {
        let msg = ChatMessage(
            threadId: threadId,
            senderName: "Me",
            senderAddress: "Me",
            isFromMe: true,
            text: text,
            timestamp: Date(),
            status: .sending,
            messageType: isRcs ? .rcs : .sms
        )

        if messageStore[threadId] == nil {
            messageStore[threadId] = []
            messageIdMap[threadId] = []
        }
        messageIdMap[threadId]?.insert(msg.id)
        messageStore[threadId]?.append(msg)

        if let idx = threads.firstIndex(where: { $0.id == threadId }) {
            threads[idx].lastMessage = text
            threads[idx].lastMessageDate = Date()
        }

        if selectedThreadId == threadId {
            updateActiveThreadMessages()
        }

        let req = OutgoingMessageRequest(
            id: msg.id,
            threadId: threadId,
            recipient: recipient,
            text: text,
            preferRcs: isRcs
        )

        if let enc = try? JSONEncoder().encode(req),
           let jsonStr = String(data: enc, encoding: .utf8) {
            let envelope = MessageEnvelope(type: .chatSend, payload: jsonStr)
            connectionManager.sendEnvelope(envelope) { success in
                Task { @MainActor in
                    self.updateMessageStatus(id: msg.id, status: success ? .sent : .failed)
                }
            }
        }
    }

    public func updateMessageStatus(id: String, status: MessageDeliveryStatus) {
        for (threadId, msgs) in messageStore {
            if let idx = msgs.firstIndex(where: { $0.id == id }) {
                messageStore[threadId]?[idx].status = status
                if selectedThreadId == threadId {
                    updateActiveThreadMessages()
                }
                break
            }
        }
    }

    public func markThreadAsRead(threadId: String) {
        if let idx = threads.firstIndex(where: { $0.id == threadId }) {
            threads[idx].unreadCount = 0
            recalculateUnreadCount()
        }
    }

    private func recalculateUnreadCount() {
        totalUnreadMessages = threads.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Call Actions
    public func receiveIncomingCall(_ call: PhoneCall) {
        self.incomingCall = call
    }

    public func answerIncomingCall() {
        guard let call = incomingCall else { return }
        incomingCall = nil

        var active = call
        active.state = .active
        active.startTime = Date()
        self.activeCall = active

        startDurationTimer()
        audioManager.answerViaHandsFree()
        audioManager.startCallAudioRouting()

        // Send answer command to phone
        let payload = CallActionPayload(callId: call.id, action: .answer)
        if let enc = try? JSONEncoder().encode(payload),
           let str = String(data: enc, encoding: .utf8) {
            connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: str))
        }
    }

    public func declineIncomingCall() {
        guard let call = incomingCall else { return }
        incomingCall = nil

        var ended = call
        ended.state = .rejected
        callHistory.insert(ended, at: 0)

        audioManager.hangupViaHandsFree()
        audioManager.stopCallAudioRouting()

        let payload = CallActionPayload(callId: call.id, action: .reject)
        if let enc = try? JSONEncoder().encode(payload),
           let str = String(data: enc, encoding: .utf8) {
            connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: str))
        }
    }

    public func dialCall(number: String, contactName: String = "") {
        let call = PhoneCall(
            phoneNumber: number,
            contactName: contactName.isEmpty ? number : contactName,
            state: .dialing,
            direction: .outgoing,
            startTime: Date()
        )
        self.activeCall = call
        startDurationTimer()

        audioManager.dialViaHandsFree(number: number)
        audioManager.startCallAudioRouting()

        let payload = CallActionPayload(callId: call.id, action: .dial, number: number)
        if let enc = try? JSONEncoder().encode(payload),
           let str = String(data: enc, encoding: .utf8) {
            connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: str))
        }
    }

    public func hangupCall() {
        guard let call = activeCall else { return }
        activeCall = nil
        callDurationTimer?.invalidate()
        callDurationTimer = nil

        var ended = call
        ended.state = .ended
        callHistory.insert(ended, at: 0)

        audioManager.hangupViaHandsFree()
        audioManager.stopCallAudioRouting()

        let payload = CallActionPayload(callId: call.id, action: .hangup)
        if let enc = try? JSONEncoder().encode(payload),
           let str = String(data: enc, encoding: .utf8) {
            connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: str))
        }
    }

    public func toggleMute() {
        guard var call = activeCall else { return }
        call.isMuted.toggle()
        activeCall = call

        let action: CallActionType = call.isMuted ? .mute : .unmute
        let payload = CallActionPayload(callId: call.id, action: action)
        if let enc = try? JSONEncoder().encode(payload),
           let str = String(data: enc, encoding: .utf8) {
            connectionManager.sendEnvelope(MessageEnvelope(type: .callAction, payload: str))
        }
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
                audioManager.stopCallAudioRouting()
            }
            if incomingCall?.id == updatedCall.id {
                incomingCall = nil
            }
            callHistory.insert(updatedCall, at: 0)
        } else if updatedCall.state == .active {
            incomingCall = nil
            activeCall = updatedCall
            startDurationTimer()
            audioManager.startCallAudioRouting()
        }
    }

    public func receiveCallSync(_ syncedCalls: [PhoneCall]) {
        var existingMap = Dictionary(uniqueKeysWithValues: callHistory.map { ($0.id, $0) })
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
                call.duration += 1
                self.activeCall = call
            }
        }
    }

    public func checkBluetoothHandsetStatus() {
        isBluetoothHandsetPaired = audioManager.isBluetoothHandsetAvailable(deviceName: pairedDevice?.name)
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
        connectionManager.unpairDevice()
        pairedDevice = nil
        threads = []
        contacts = []
        apps = []
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
            self.threads = savedThreads
            self.selectedThreadId = savedThreads.first?.id
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
            self.notifications = savedNotifs
            self.unreadNotificationCount = savedNotifs.count
        }
        recalculateUnreadCount()

        // 2. Offload large 12,000+ message cache parsing and id set indexing completely to background thread
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([String: [ChatMessage]], [String: Set<String>])? in
                guard let mData = try? Data(contentsOf: mUrl),
                      let msgs = try? JSONDecoder().decode([String: [ChatMessage]].self, from: mData) else { return nil }
                var idMap: [String: Set<String>] = [:]
                for (tId, list) in msgs {
                    idMap[tId] = Set(list.map { $0.id })
                }
                return (msgs, idMap)
            }.value

            if let (msgs, idMap) = result {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.messageStore = msgs
                    self.messageIdMap = idMap
                    self.updateActiveThreadMessages()
                    self.recalculateUnreadCount()
                }
            }
        }
    }

    private var saveCacheTask: Task<Void, Never>?

    private func saveCachedData() {
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
