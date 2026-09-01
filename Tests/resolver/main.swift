import Foundation

var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("\(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !pass { failures += 1 }
}

let macros = [
    Macro(name: "Claude", phrases: ["wake up daddys home", "daddys home", "claude"],
          kind: .app, target: "/Users/x/Desktop/Claude.app"),
    Macro(name: "Weather", phrases: ["the weather", "weather", "whats it like outside", "forecast"],
          kind: .weather, target: ""),
    Macro(name: "Gmail", phrases: ["gmail", "my email", "email"], kind: .url,
          target: "https://mail.google.com"),
    Macro(name: "Minecraft", phrases: ["the craft", "minecraft"], kind: .app,
          target: "/Applications/Minecraft.app"),
]

print("=== indexing installed apps ===")
let entries = AppIndex.shared.refresh()
print("indexed \(entries.count) apps\n")

print("=== verb interchangeability ===")
for verb in ["open", "start", "start up", "launch", "fire up", "boot up", "run", "pull up"] {
    let r = Resolver.resolveFast(transcript: "\(verb) the craft", macros: macros)
    check("\"\(verb) the craft\" -> Minecraft", r?.macro.name == "Minecraft",
          r.map { "\($0.macro.name) \(String(format: "%.2f", $0.confidence))" } ?? "nil")
}

print("\n=== macros ===")
let macroCases: [(String, String)] = [
    ("wake up daddy's home", "Claude"),
    ("Wake up, daddy's home!", "Claude"),
    ("jarvis open claude", "Claude"),
    ("hey jarvis, start up claude", "Claude"),
    ("jarvis, open my email", "Gmail"),
    ("open gmail", "Gmail"),
    ("what's it like outside", "Weather"),
    ("jarvis what's the weather", "Weather"),
    ("start up the craft", "Minecraft"),
]
for (said, expect) in macroCases {
    let r = Resolver.resolveFast(transcript: said, macros: macros)
    check("\"\(said)\" -> \(expect)", r?.macro.name == expect,
          r.map { "\($0.macro.name) \(String(format: "%.2f", $0.confidence)) via \($0.source.rawValue)" } ?? "nil")
}

print("\n=== installed apps with no macro ===")
for (said, expect) in [("open google chrome", "Google Chrome"), ("launch chrome", "Google Chrome"),
                       ("open safari", "Safari"), ("start up visual studio code", "Visual Studio Code"),
                       ("open audacity", "Audacity"), ("fire up xcode", "Xcode")] {
    let r = Resolver.resolveFast(transcript: said, macros: macros)
    check("\"\(said)\" -> \(expect)", r?.macro.name == expect,
          r.map { "\($0.macro.name) via \($0.source.rawValue)" } ?? "nil")
}

print("\n=== regression: no launcher macro means no wrong guess ===")
// The exact shape of the reported bug: "the craft" with no Minecraft macro
// must resolve to nothing, never to Weather.
let withoutMinecraft = macros.filter { $0.name != "Minecraft" }
let r = Resolver.resolveFast(transcript: "start up the craft", macros: withoutMinecraft)
check("\"start up the craft\" with no launcher macro -> nothing", r == nil,
      r.map { $0.macro.name } ?? "nil")
check("Prism Launcher is indexed (it lives in ~/Downloads)",
      entries.contains { $0.normalized.contains("prism") },
      "\(entries.count) apps")
for said in ["open prism launcher", "launch prism"] {
    let r = Resolver.resolveFast(transcript: said, macros: withoutMinecraft)
    check("\"\(said)\" -> Prism Launcher", r?.macro.name == "Prism Launcher",
          r?.macro.name ?? "nil")
}

print("\n=== must NOT fire ===")
for said in ["", "what time is it", "hey how are you doing today", "um", "uh huh okay",
             "so anyway I was telling him about the thing", "no thanks"] {
    let r = Resolver.resolveFast(transcript: said, macros: macros)
    check("\"\(said)\" -> nothing", r == nil,
          r.map { "\($0.macro.name) \(String(format: "%.2f", $0.confidence))" } ?? "nil")
}

print("\n\(failures == 0 ? "ALL RESOLVER TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
