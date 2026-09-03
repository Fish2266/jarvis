import Foundation
import Carbon.HIToolbox

// The keyboard trigger. A global hot key takes its combination away from every
// other app for as long as it's registered, so the table of what can be bound
// is worth pinning down: no duplicates, nothing bound to a bare key, and "off"
// really meaning off.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

print("=== the shortcut table ===")

check("off binds nothing", TriggerShortcut.off.keyCode == nil
      && TriggerShortcut.off.modifiers == 0)

check("\u{2318}J is the default the menu starts on",
      TriggerShortcut.commandJ.keyCode == UInt32(kVK_ANSI_J)
      && TriggerShortcut.commandJ.modifiers == UInt32(cmdKey))

// A bare key would swallow that key system-wide the moment Jarvis launched.
for shortcut in TriggerShortcut.allCases where shortcut != .off {
    check("\(shortcut.title) carries a modifier", shortcut.modifiers != 0)
    check("\(shortcut.title) names a key", shortcut.keyCode != nil)
}

print("\n=== no two entries are the same binding ===")
var seen: [String: TriggerShortcut] = [:]
for shortcut in TriggerShortcut.allCases where shortcut != .off {
    let key = "\(shortcut.keyCode ?? 0)/\(shortcut.modifiers)"
    check("\(shortcut.title) is unique", seen[key] == nil,
          seen[key].map { "clashes with \($0.title)" } ?? "")
    seen[key] = shortcut
}

print("\n=== the ones that will annoy you say so ===")
// ⌘J is Finder's View Options and Xcode's jump bar. Binding it globally is a
// real cost, and the menu has to admit that rather than let you discover it.
check("\u{2318}J warns about the conflict", TriggerShortcut.commandJ.note != nil,
      TriggerShortcut.commandJ.note ?? "no note")
check("off needs no warning", TriggerShortcut.off.note == nil)

print("\n=== every case survives a round trip through the preference ===")
for shortcut in TriggerShortcut.allCases {
    check("\(shortcut.title) round-trips",
          TriggerShortcut(rawValue: shortcut.rawValue) == shortcut)
}
check("an unknown stored value falls back to the default",
      TriggerShortcut(rawValue: 99) == nil, "Prefs turns nil into \u{2318}J")

print(failures == 0 ? "\nALL TRIGGER TESTS PASSED" : "\n\(failures) TRIGGER TESTS FAILED")
exit(failures == 0 ? 0 : 1)
