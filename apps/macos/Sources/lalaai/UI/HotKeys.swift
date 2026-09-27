import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts that work while Keynote/PowerPoint is frontmost (Carbon hotkeys need no permissions).
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    func register(_ bindings: [(key: Int, action: () -> Void)]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { me.actions[id.id]?() }
            return noErr
        }, 1, &spec, me, &handler)
        for (i, b) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C4C4149), id: UInt32(i + 1)) // 'LLAI'
            RegisterEventHotKey(UInt32(b.key), Self.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
            actions[UInt32(i + 1)] = b.action
        }
    }
}
