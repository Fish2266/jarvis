import Foundation

// Regression cover for the issues found in the September 2026 audit. Every case
// here failed, or was unverified, before the corresponding fix.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

print("=== normalize: the byte-wise fast path matches the folding path ===")
// Same string, once as pure ASCII and once forced onto the Unicode path by a
// trailing character that folds away to nothing visible.
for (ascii, wide) in [
    ("open chrome on work", "open chrome on work\u{00A0}"),
    ("wake up daddys home", "wake up daddy\u{2019}s home"),
    ("REMIND ME TO CALL MOM", "REMIND ME TO CALL MOM\u{00A0}"),
] {
    let a = PhraseMatcher.normalize(ascii)
    let w = PhraseMatcher.normalize(wide)
    check("\"\(ascii)\" agrees across both paths", a == w, "\(a) / \(w)")
}
check("apostrophes still join words",
      PhraseMatcher.normalize("daddy's") == "daddys")
check("curly apostrophes too",
      PhraseMatcher.normalize("daddy\u{2019}s") == "daddys")
check("diacritics still fold",
      PhraseMatcher.normalize("café") == "cafe")
check("runs of punctuation collapse to one space",
      PhraseMatcher.normalize("a!!!  ...b") == "a b")
check("leading and trailing junk is trimmed",
      PhraseMatcher.normalize("  ...hello...  ") == "hello")
check("empty stays empty", PhraseMatcher.normalize("") == "")
check("all-punctuation yields nothing", PhraseMatcher.normalize("!!!") == "")
check("digits survive", PhraseMatcher.normalize("Profile 1") == "profile 1")

print("\n=== the length guard added to token matching changes no answers ===")
// tokenMatches skips the edit-distance matrix when the lengths differ by more
// than the budget. That is exact, because distance >= length difference.
for (a, b, want) in [
    ("chrome", "chrome", true),
    ("chrom", "chrome", true),
    ("chrome", "chromee", true),
    ("chr", "chrome", false),
    ("chromeee", "chrome", false),
    ("to", "to", true),
    ("to", "too", false),          // under four letters: no typo budget at all
    ("remind", "reminder", false),
] {
    check("tokenMatches(\"\(a)\", \"\(b)\") == \(want)",
          PhraseMatcher.tokenMatches(a, b) == want)
}

print("\n=== which open tab counts as the same page ===")
for (tab, target, want) in [
    // Regression: "www." was stripped from anywhere in the host rather than
    // only the front, so a host with it in the middle collapsed onto a
    // different site and a command jumped to the wrong tab.
    ("https://mail.www.google.com/", "https://mail.google.com", false),
    ("https://a.www.b.com/x", "https://a.b.com", false),
    // The leading "www." it is actually meant to ignore still goes.
    ("https://www.example.com/x", "https://example.com", true),
    ("https://example.com/x", "https://www.example.com", true),
    // A target written with a trailing slash matches the tab without one.
    ("https://example.com/mail", "https://example.com/mail/", true),
    ("https://example.com/mail/inbox", "https://example.com/mail/", true),
    ("https://example.com/mailbox", "https://example.com/other", false),
    // Cases the original already handled, kept so the fix can't regress them.
    ("https://mail.google.com/mail/u/0/#inbox", "https://mail.google.com", true),
    ("https://drive.google.com/drive", "https://mail.google.com", false),
    ("https://example.com/a/b", "https://example.com/a", true),
    ("https://example.com/z", "https://example.com/a", false),
] {
    check("\(tab) ~ \(target) = \(want)",
          Browser.tabMatches(tab, target: target) == want)
}

print("\n=== resolution is unchanged by the matcher rewrite ===")
let macros = Macro.seeded()
for (said, expected) in [
    ("open chrome", "Chrome"), ("start up the craft", "Minecraft"),
    ("the weather", "Weather"), ("good night", "Sleep"),
    ("remind me to call mom", "Reminder"), ("gmail", "Gmail"),
    ("wake up daddys home", "Claude"),
] {
    let got = Resolver.resolveFast(transcript: said, macros: macros)?.macro.name
    // Only assert on commands this Mac actually seeded (Claude/Minecraft/Chrome
    // depend on what is installed).
    if macros.contains(where: { $0.name == expected }) {
        check("\"\(said)\" -> \(expected)", got == expected, got ?? "nothing")
    } else {
        print("SKIP  \"\(said)\" -> \(expected) (not installed here)")
    }
}
for said in ["how do i sleep better", "tell me about sleep", "what should i eat"] {
    check("\"\(said)\" resolves to nothing",
          Resolver.resolveFast(transcript: said, macros: macros) == nil)
}

print("\n=== normalize is no longer the cost of resolving ===")
let phrase = "Hey Jarvis, could you please fire up the craft for me right now?"
var sink = 0
let t0 = DispatchTime.now().uptimeNanoseconds
for _ in 0..<200_000 { sink &+= PhraseMatcher.normalize(phrase).count }
let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3 / 200_000
check("under 3 µs a call", us < 3.0, String(format: "%.2f µs (sink %d)", us, sink))

print(failures == 0 ? "\nALL AUDIT TESTS PASSED" : "\n\(failures) AUDIT TESTS FAILED")
exit(failures == 0 ? 0 : 1)
