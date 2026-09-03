import Carbon.HIToolbox
import AppKit

/// Reads which hot key a Carbon event was for.
///
/// Every handler installed on the application event target is called for every
/// hot key, not just its own, so both of Jarvis's hot keys have to check.
enum HotKeyEvent {
    static func id(of event: EventRef?) -> UInt32? {
        guard let event else { return nil }
        var hotKey = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        guard status == noErr, hotKey.signature == EscapeHotKey.signature else { return nil }
        return hotKey.id
    }
}

/// A global shortcut that arms Jarvis, for when clapping isn't appropriate.
///
/// Carbon hot keys again, and for the same reason `EscapeHotKey` uses them: no
/// Accessibility, no Input Monitoring, no event tap, no permission prompt of any
/// kind. Unlike Escape, this one is registered for as long as Jarvis is enabled
/// rather than for a few seconds after a clap — so it genuinely does take the
/// combination away from everything else, which is why it can be changed and
/// turned off.
///
/// It sits alongside the claps rather than replacing them: both call `arm()`.
final class TriggerHotKey {

    static let shared = TriggerHotKey()
    private init() {}

    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let hotKeyID: UInt32 = 2

    private(set) var bound: TriggerShortcut = .off

    var isRegistered: Bool { hotKey != nil }

    /// Whether the last attempt to bind a real combination was refused because
    /// something else already owns it.
    ///
    /// Not the same question as `isRegistered`, which is also false when Jarvis
    /// is simply paused and has handed the combination back on purpose. Cleared
    /// by `apply` and deliberately untouched by `unregister`.
    private(set) var conflicted = false

    /// Binds whatever the preference currently says. Safe to call repeatedly —
    /// it unbinds the old combination first.
    @discardableResult
    func apply(_ shortcut: TriggerShortcut) -> Bool {
        unregister()
        bound = shortcut
        conflicted = false
        guard let key = shortcut.keyCode else { return true }
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: EscapeHotKey.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(key, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            // Almost always because another app registered it first. Nothing to
            // be done about that from here, so say so and carry on clapping.
            hotKey = nil
            conflicted = true
            return false
        }
        return true
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard HotKeyEvent.id(of: event) == TriggerHotKey.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { TriggerHotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
