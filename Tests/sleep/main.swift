import Foundation

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let macros = try! JSONDecoder().decode(
    [Macro].self, from: try! Data(contentsOf: here.appendingPathComponent("../questions/macros.json")))
_ = AppIndex.shared.refresh()
func resolve(_ s: String) -> Resolution? { Resolver.resolveFast(transcript: s, macros: macros) }

print("=== these put the Mac to sleep ===")
for said in ["sleep", "jarvis sleep", "jarvis, sleep", "go to sleep", "power down",
             "jarvis power down", "night night", "jarvis night night", "good night",
             "goodnight", "go to bed", "time for bed", "lights out", "nap time"] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.kind == .sleep, r?.macro.name ?? "nothing")
}

print("\n=== these must NOT ===")
// Fuzzy containment would fire on every one of these.
for said in ["how do i sleep better", "remind me to go to sleep early",
             "what time should i go to sleep", "tell me about sleep",
             "is my mac asleep", "open sleep cycle", "power down chrome",
             // A verb in front means you are asking to open or fetch something
             // called Sleep, not to sleep the Mac. These used to sleep it.
             "open sleep", "launch sleep", "start sleep", "get me sleep",
             "bring over sleep", "bring sleep here", "bring me good night",
             "remind me to say good night to grandma", "whats a good night light",
             "open chrome", "start up the craft", "what's the weather"] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.kind != .sleep,
          r.map { "\($0.macro.name) (\($0.macro.kind.rawValue))" } ?? "nothing")
}

print("\n=== the model can never choose it ===")
let offered = Resolver.candidates(macros: macros)
check("sleep is withheld from the model's list",
      !offered.contains { $0.kind == .sleep },
      offered.map(\.name).joined(separator: ", "))
for named in ["Sleep", "sleep", "go to bed", "power down"] {
    let r = Resolver.resolveNamed(named, macros: macros)
    check("model naming \"\(named)\" can't reach it", r?.macro.kind != .sleep,
          r?.macro.name ?? "nothing")
}

print("\n=== it speaks for itself, so no second reply ===")
check("sleep handles its own reply", ActionKind.sleep.handlesOwnReply)
check("other kinds don't", !ActionKind.app.handlesOwnReply && !ActionKind.url.handlesOwnReply)

print("\n\(failures == 0 ? "ALL SLEEP TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
