import AppKit
import Carbon

/// A system hotkey remains available while scrcpy's borderless window owns keyboard focus.
@MainActor
final class StreamCloseShortcut {
    static let shared = StreamCloseShortcut()
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier = EventHotKeyID(signature: 0x44445131, id: 1) // DDQ1
    func register() {
        guard hotkey == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == 0x44445131, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in NativeMirrorManager.shared.closeStreams() }
            return noErr
        }, 1, &event, nil, &handler)
        guard status == noErr else { return }
        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        if RegisterEventHotKey(UInt32(kVK_ANSI_Q), modifiers, identifier, GetApplicationEventTarget(), 0, &hotkey) != noErr {
            if let handler { RemoveEventHandler(handler) }; handler = nil
        }
    }
    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
