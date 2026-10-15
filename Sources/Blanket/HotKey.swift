import Carbon
import Foundation

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey, which works without the
/// Accessibility permission and while another app is frontmost.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void
    private static var nextID: UInt32 = 1

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
    static let keyR = UInt32(kVK_ANSI_R)

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if hkID.id == me.id { me.callback() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        guard status == noErr else { return nil }

        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x424C4B54), id: id)  // "BLKT"
        let reg = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard reg == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    private var id: UInt32 = 0

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
