import Carbon.HIToolbox
import AppKit

/// A system-wide Escape key, live only while Jarvis is listening.
///
/// Uses the Carbon hot-key API rather than an event tap on purpose: this needs
/// no Accessibility or Input Monitoring permission, and because it's registered
/// only for the few seconds after a double clap, it isn't swallowing Escape from
/// anything else the rest of the time.
final class EscapeHotKey {

    static let shared = EscapeHotKey()
    private init() {}

    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private static let signature: OSType = 0x4A525653   // 'JRVS'

    func register() {
        guard hotKey == nil else { return }
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    var isRegistered: Bool { hotKey != nil }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { EscapeHotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
