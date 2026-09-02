import Foundation

func ms(_ s: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(s) * 1000) }
var failures = 0
func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("\(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !pass { failures += 1 }
}

@main
struct P {
    static func main() async {
        print("=== sanitize (reliability guard) ===")
        check("passes a normal line", Intelligence.sanitize("Claude is up, sir.") == "Claude is up, sir.")
        check("strips wrapping quotes", Intelligence.sanitize("\"Chrome is ready, sir.\"") == "Chrome is ready, sir.")
        check("rejects nil", Intelligence.sanitize(nil) == nil)
        check("rejects empty", Intelligence.sanitize("   ") == nil)
        check("rejects a rambling answer",
              Intelligence.sanitize(String(repeating: "word ", count: 40)) == nil)
        check("flattens newlines",
              Intelligence.sanitize("Chrome is up, sir.\nAs requested.") == "Chrome is up, sir. As requested.")
        check("drops a trailing question but keeps the line",
              Intelligence.sanitize("Minecraft is running, sir. Ready to craft?") == "Minecraft is running, sir.")
        check("rejects a line that is only a question",
              Intelligence.sanitize("Shall I open something else?") == nil)

        let intel = Intelligence.shared
        print("\n=== availability ===")
        print("available: \(intel.isAvailable), reason: \(intel.unavailableReason ?? "-")")
        guard intel.isAvailable else { print("skipping model tests"); return }

        let macros = [
            Macro(name: "Claude", phrases: ["daddys home", "claude"], kind: .app, target: "/x/Claude.app"),
            Macro(name: "Weather", phrases: ["the weather"], kind: .weather, target: ""),
            Macro(name: "Gmail", phrases: ["gmail", "my email"], kind: .url, target: "https://mail.google.com"),
            Macro(name: "Minecraft", phrases: ["the craft"], kind: .app, target: "/x/Minecraft.app"),
            Macro(name: "Spotify", phrases: ["spotify"], kind: .app, target: "/x/Spotify.app"),
        ]

        print("\n=== tier 2: fresh session per call, prewarmed ===")
        intel.prewarm()
        try? await Task.sleep(nanoseconds: 2_500_000_000)   // mimic the listening window

        // Phrasings the deterministic resolver would genuinely miss.
        let cases: [(String, String?)] = [
            ("I could go for some blocky building", "Minecraft"),
            ("is it going to rain on me", "Weather"),
            ("check my inbox", "Gmail"),
            ("put a record on", "Spotify"),
            ("mumble mumble nonsense wibble", nil),
            // The reported bug: this must never fall through to Weather.
            ("start up the craft", "Minecraft"),
        ]
        _ = AppIndex.shared.refresh()
        var hits = 0, scored = 0
        for (said, expect) in cases {
            let t = Date()
            let named = await intel.resolveTarget(transcript: said, commands: macros.map(\.name))
            let got = named.flatMap { Resolver.resolveNamed($0, macros: macros)?.macro.name }
            if expect == nil {
                // Safety property: idle speech must never fire an action.
                check("idle speech \"\(said)\" fires nothing", got == nil, "\(got ?? "nil"), \(ms(t))")
            } else {
                scored += 1
                if got == expect { hits += 1 }
                print("  \(got == expect ? "hit " : "miss") \"\(said)\" -> \(got ?? "nothing") (want \(expect!))  [\(ms(t))]")
            }
        }
        check("paraphrase understanding >= 3/\(scored)", hits >= 3, "\(hits)/\(scored)")

        print("\n=== tier 3: spoken replies ===")
        for (action, heard) in [("Opening Claude", "wake up daddys home"),
                                ("Opening Minecraft", "start up the craft"),
                                ("Checking the weather: 71°F · Clear sky", "whats it like outside")] {
            let t = Date()
            let line = await intel.reply(action: action, heard: heard)
            let words = line.split(separator: " ").count
            check("reply for \(action) is short & non-empty", words >= 1 && words <= 18, "\(ms(t))")
            print("      \(line)")
        }

        print("\n=== timeout safety ===")
        let t = Date()
        let line = await intel.reply(action: "Opening Claude", heard: "", timeout: 0.001)
        check("impossible timeout still returns a canned line",
              Intelligence.cannedReplies.contains(line), "\(line), \(ms(t))")
        // The timeout has to actually bound the wait, not merely decide what to
        // return once the model finishes in its own time. The old helper waited
        // on a task group, so a slow generation held the caller — and the HUD —
        // for however long it took, whatever the timeout said.
        check("...and returns at the deadline rather than when the model finishes",
              Date().timeIntervalSince(t) < 1.0, ms(t))

        let answerStart = Date()
        _ = await intel.answer("give me a long rambling history of the roman empire",
                               timeout: 0.05)
        check("a slow answer is abandoned, not waited out",
              Date().timeIntervalSince(answerStart) < 1.5, ms(answerStart))

        print("\n\(failures == 0 ? "ALL INTELLIGENCE TESTS PASSED" : "\(failures) FAILURE(S)")")
        exit(failures == 0 ? 0 : 1)
    }
}
