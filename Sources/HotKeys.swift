import Carbon.HIToolbox

/// Global hotkeys (work from any app) via RegisterEventHotKey.
/// No Accessibility permission required.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let ctx {
                let hk = Unmanaged<HotKeys>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async { hk.actions[id.id]?() }
            }
            return noErr
        }, 1, &spec, me, &handler)
    }

    @discardableResult
    func register(_ shortcut: Shortcut, _ action: @escaping () -> Void) -> Bool {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: OSType(0x4D52_4D52), id: id), // 'MRMR'
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Murmur: couldn't register hotkey \(shortcut.display): \(status)") }
        if let ref { refs.append(ref) }
        return status == noErr
    }

    var count: Int { refs.count }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}
