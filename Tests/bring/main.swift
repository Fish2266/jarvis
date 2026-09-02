import Foundation

// "bring over xcode" — the app comes to the desktop you're on, rather than the
// desktop coming to you. Covers the parsing half; the window-server half lives
// in Spaces.swift and is exercised by Tests/live.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

let macros: [Macro] = [
    Macro(name: "Xcode", phrases: ["xcode"], kind: .app, target: "/Applications/Xcode.app"),
    Macro(name: "Chrome", phrases: ["chrome", "google chrome", "new tab", "the browser"],
          kind: .app, target: "/Applications/Google Chrome.app"),
    Macro(name: "Sleep", phrases: ["sleep", "good night"], kind: .sleep, target: ""),
    Macro(name: "Reminder", phrases: ["remind me to", "remind me"], kind: .reminder, target: ""),
    Macro(name: "Gmail", phrases: ["gmail", "my email"], kind: .url,
          target: "https://mail.google.com"),
]

func resolve(_ said: String) -> Resolution? {
    Resolver.resolveFast(transcript: said, macros: macros)
}

print("=== these bring the app to you ===")
for said in [
    "bring over xcode", "bring xcode", "bring xcode over", "bring xcode here",
    "bring xcode over here", "bring over the browser", "move over xcode",
    "send over xcode", "pull over xcode", "bring me xcode", "drag over xcode",
    "jarvis bring over xcode", "jarvis, bring xcode over here", "gimme xcode",
] {
    let r = resolve(said)
    check("\"\(said)\"", r?.bringHere == true && r?.macro.kind == .app,
          "\(r?.macro.name ?? "nothing") bringHere=\(r?.bringHere.description ?? "-")")
}

print("\n=== these still just open, exactly as before ===")
for said in [
    "open xcode", "launch xcode", "start up xcode", "fire up xcode",
    "bring up xcode", "pull up xcode", "boot up xcode", "open up xcode",
    "take me to xcode", "show me xcode", "go to xcode", "get me xcode",
    "jarvis open xcode", "would you kindly open xcode",
] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.name == "Xcode" && r?.bringHere == false,
          "\(r?.macro.name ?? "nothing") bringHere=\(r?.bringHere.description ?? "-")")
}

print("\n=== the target survives the verb ===")
for (said, want) in [("bring over xcode", "Xcode"), ("bring chrome over", "Chrome"),
                     ("bring over the browser", "Chrome"), ("bring gmail here", "Gmail"),
                     ("bring over google chrome", "Chrome")] {
    check("\"\(said)\" -> \(want)", resolve(said)?.macro.name == want,
          resolve(said)?.macro.name ?? "nothing")
}

print("\n=== a bare direction word isn't a command ===")
for said in ["bring", "bring over", "bring here", "bring me", "move over", "over here"] {
    let r = resolve(said)
    check("\"\(said)\" resolves to nothing", r == nil, r?.macro.name ?? "nothing")
}

print("\n=== bringing can't reach the exact-phrase commands ===")
// Sleep must stay unreachable by anything but its own phrase said plainly.
for said in ["bring over sleep", "bring sleep here", "bring me good night"] {
    let r = resolve(said)
    check("\"\(said)\" doesn't sleep the Mac", r?.macro.kind != .sleep,
          r?.macro.name ?? "nothing")
}

print("\n=== dictation is untouched by the tail stripper ===")
// "over", "here", "to", "me", "now" are only stripped after a bring verb.
for (said, want) in [("remind me to bring the car over here", "bring the car over here"),
                     ("remind me to move over my files", "move over my files"),
                     ("remind me to call mom now", "call mom now")] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.kind == .reminder && r?.payload == want,
          r?.payload ?? "nothing")
}

print("\n=== strip() reports the verb it used ===")
for (text, target, verb, bring) in [
    ("bring over xcode", "xcode", true, true),
    ("bring up xcode", "xcode", true, false),
    ("open xcode", "xcode", true, false),
    ("xcode", "xcode", false, false),
    ("bring xcode over here", "xcode", true, true),
] {
    let got = Resolver.strip(text)
    check("strip(\"\(text)\")",
          got.target == target && got.sawVerb == verb && got.bringHere == bring,
          "\(got)")
}

print("\n=== finding the running app to bring ===")
check("an app running from its own path is found",
      Spaces.runningApp(atPath: "/System/Library/CoreServices/Finder.app") != nil)
check("a path with no app there yields nothing",
      Spaces.runningApp(atPath: "/Applications/DefinitelyNotReal.app") == nil)
check("an empty path yields nothing", Spaces.runningApp(atPath: "") == nil)

// The Minecraft bug: anything launched from Downloads runs translocated, so
// the running app's bundleURL is a random path under /private/var/folders and
// never equals where the command points. A bundle that claims an identifier
// belonging to a running app is the same shape — same identity, wrong path.
let fake = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("JarvisTranslocationTest.app")
try? FileManager.default.createDirectory(at: fake.appendingPathComponent("Contents"),
                                         withIntermediateDirectories: true)
let info: [String: Any] = ["CFBundleIdentifier": "com.apple.finder",
                           "CFBundleExecutable": "Finder"]
if let data = try? PropertyListSerialization.data(fromPropertyList: info,
                                                  format: .xml, options: 0) {
    try? data.write(to: fake.appendingPathComponent("Contents/Info.plist"))
}
let byIdentifier = Spaces.runningApp(atPath: fake.path)
check("an app running from a different path is still found, by its identifier",
      byIdentifier?.bundleIdentifier == "com.apple.finder",
      byIdentifier?.bundleURL?.path ?? "nil")
try? FileManager.default.removeItem(at: fake)

print(failures == 0 ? "\nALL BRING TESTS PASSED" : "\n\(failures) BRING TESTS FAILED")
exit(failures == 0 ? 0 : 1)
