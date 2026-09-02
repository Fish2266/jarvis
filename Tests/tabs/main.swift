import Foundation

// "open a new tab" used to resolve to the Chrome command and then just activate
// Chrome, because opening an app that is already running only raises its
// existing window. These pin the parsing half of the fix.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

let chromePath = "/Applications/Google Chrome.app"
let macros: [Macro] = [
    // The seeded phrase list, kept in step with Macro.seeded().
    Macro(name: "Chrome", phrases: ["chrome", "google chrome", "new tab", "a new tab",
                                    "another tab", "new window", "another window",
                                    "the browser", "browser"],
          kind: .app, target: chromePath),
    Macro(name: "Gmail", phrases: ["gmail", "my email"], kind: .url,
          target: "https://mail.google.com"),
    Macro(name: "Xcode", phrases: ["xcode"], kind: .app, target: "/Applications/Xcode.app"),
    Macro(name: "Reminder", phrases: ["remind me to", "remind me"], kind: .reminder, target: ""),
]
func resolve(_ s: String) -> Resolution? { Resolver.resolveFast(transcript: s, macros: macros) }

print("=== these ask Chrome for a tab ===")
for said in ["open a new tab", "new tab", "open new tab", "a new tab",
             "jarvis open a new tab", "give me a new tab", "open up a new tab",
             "make a new tab", "pull up a new tab", "open a new browser tab",
             // These reach the command through its phrase list; stripNewQualifier
             // reduces "another tab" to nothing on its own.
             "another tab", "open another tab"] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.name == "Chrome" && r?.browserFresh == .tab,
          "\(r?.macro.name ?? "nothing") fresh=\(r?.browserFresh.map(\.rawValue) ?? "nil")")
}

print("\n=== these ask for a window ===")
for said in ["open a new window", "new window", "open new window",
             "jarvis open a new window", "another window", "open another window"] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.name == "Chrome" && r?.browserFresh == .window,
          "\(r?.macro.name ?? "nothing") fresh=\(r?.browserFresh.map(\.rawValue) ?? "nil")")
}

print("\n=== plain Chrome is still plain Chrome ===")
for said in ["open chrome", "chrome", "google chrome", "the browser", "open the browser"] {
    let r = resolve(said)
    check("\"\(said)\" makes nothing fresh",
          r?.macro.name == "Chrome" && r?.browserFresh == nil,
          "fresh=\(r?.browserFresh.map(\.rawValue) ?? "nil")")
}

print("\n=== a website command is unaffected — it has forceNewTab ===")
for (said, force) in [("open gmail", false), ("open a new gmail tab", true)] {
    let r = resolve(said)
    check("\"\(said)\" -> Gmail, forceNewTab=\(force), fresh=nil",
          r?.macro.name == "Gmail" && r?.forceNewTab == force && r?.browserFresh == nil,
          "\(r?.macro.name ?? "nothing") force=\(r?.forceNewTab.description ?? "-") fresh=\(r?.browserFresh.map(\.rawValue) ?? "nil")")
}

print("\n=== \"window\" beats \"tab\" when both are said ===")
check("\"open a new tab in a new window\" -> window",
      resolve("open a new tab in a new window")?.browserFresh == .window)
check("freshBrowser reads the words directly",
      Resolver.freshBrowser(in: "open a new tab") == .tab
        && Resolver.freshBrowser(in: "open a new window") == .window
        && Resolver.freshBrowser(in: "open chrome") == nil
        && Resolver.freshBrowser(in: "close the tabs") == .tab)

print("\n=== dictation keeps its words ===")
// "tab" and "window" inside a reminder must not become a browser request.
for (said, want) in [("remind me to open a new tab", "open a new tab"),
                     ("remind me to clean the window", "clean the window")] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.kind == .reminder && r?.payload == want
            && r?.browserFresh == nil,
          "\(r?.payload ?? "nothing") fresh=\(r?.browserFresh.map(\.rawValue) ?? "nil")")
}

print("\n=== a non-browser app ignores it ===")
// Only the browser can be asked for a tab; Xcode just opens.
check("\"open a new xcode window\" resolves to Xcode",
      resolve("open a new xcode window")?.macro.name == "Xcode",
      resolve("open a new xcode window")?.macro.name ?? "nothing")

print(failures == 0 ? "\nALL TAB TESTS PASSED" : "\n\(failures) TAB TESTS FAILED")
exit(failures == 0 ? 0 : 1)
