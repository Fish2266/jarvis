import Foundation

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let macros = try! JSONDecoder().decode(
    [Macro].self, from: Data(contentsOf: here.appendingPathComponent("macros.json")))
_ = AppIndex.shared.refresh()
let profiles = Browser.chromeProfiles()
let school = profiles.first { $0.name == "Work" }?.directory
let personal = profiles.first { $0.name == "Connor" }?.directory
print("profiles: \(profiles.map(\.name)) -> school=\(school ?? "?") personal=\(personal ?? "?")\n")

func resolve(_ s: String) -> Resolution? { Resolver.resolveFast(transcript: s, macros: macros) }

print("=== spoken Chrome profiles ===")
let profileCases: [(String, String, String?)] = [
    ("open chrome on work", "Chrome", school),
    ("open chrome on school", "Chrome", school),
    ("open chrome with personal", "Chrome", personal),
    ("launch chrome on connor", "Chrome", personal),
    ("start up chrome on my work one", "Chrome", school),
    ("open chrome using my personal profile", "Chrome", personal),
]
for (said, name, profile) in profileCases {
    let r = resolve(said)
    let ok = r?.macro.name == name && r?.chromeProfile == profile
    check("\"\(said)\"", ok,
          "\(r?.macro.name ?? "nil") / \(Browser.profileName(for: r?.chromeProfile) ?? "none")")
}

print("\n=== new tab ===")
for (said, profile) in [("open new tab on work", school), ("open a new tab on personal", personal),
                        ("open new window on school", school), ("new tab on personal", personal)] {
    let r = resolve(said)
    let ok = r?.macro.name == "Chrome" && r?.chromeProfile == profile
    check("\"\(said)\"", ok,
          "\(r?.macro.name ?? "nil") / \(Browser.profileName(for: r?.chromeProfile) ?? "none")")
}

print("\n=== spoken profile overrides the pinned one ===")
for (said, name, profile) in [("open gmail on personal", "Gmail", personal),
                              ("open youtube on work", "YouTube", school)] {
    let r = resolve(said)
    check("\"\(said)\" overrides to \(Browser.profileName(for: profile) ?? "?")",
          r?.macro.name == name && r?.chromeProfile == profile,
          "\(r?.macro.name ?? "nil") / \(Browser.profileName(for: r?.chromeProfile) ?? "none")")
}
// With no spoken profile the command keeps its own.
let gmail = resolve("open gmail")
check("\"open gmail\" keeps its pinned Work profile",
      gmail?.macro.name == "Gmail" && gmail?.chromeProfile == nil
        && gmail?.macro.chromeProfile == school,
      Browser.profileName(for: gmail?.macro.chromeProfile) ?? "none")
let bare = resolve("open chrome")
check("\"open chrome\" names no profile", bare?.macro.name == "Chrome" && bare?.chromeProfile == nil,
      bare?.chromeProfile ?? "none")

print("\n=== a stray connector must not look like a profile ===")
for said in ["open sign in with google", "what's it like outside", "start up the craft"] {
    let r = resolve(said)
    check("\"\(said)\" picks no profile", r?.chromeProfile == nil,
          Browser.profileName(for: r?.chromeProfile) ?? "none")
}

print("\n=== reuse an open tab, or force a new one ===")
for (said, name, forceNew) in [("open gmail", "Gmail", false),
                               ("open new gmail", "Gmail", true),
                               ("open a new gmail tab", "Gmail", true),
                               ("open another youtube tab", "YouTube", true),
                               ("open youtube", "YouTube", false),
                               ("pull up a new netflix window", "Netflix", true)] {
    let r = resolve(said)
    check("\"\(said)\" -> \(name), new=\(forceNew)",
          r?.macro.name == name && r?.forceNewTab == forceNew,
          "\(r?.macro.name ?? "nil") new=\(r?.forceNewTab.description ?? "nil")")
}

print("\n=== \"new tab\" is still the Chrome command ===")
for (said, profile) in [("open new tab", nil as String?), ("open a new tab on work", school),
                        ("open new window on school", school)] {
    let r = resolve(said)
    check("\"\(said)\" -> Chrome, not a forced new anything-else",
          r?.macro.name == "Chrome" && r?.forceNewTab == false && r?.chromeProfile == profile,
          "\(r?.macro.name ?? "nil") new=\(r?.forceNewTab.description ?? "nil")")
}

print("\n=== regression: a short word must not grab a whole app ===")
// "open new" used to score 0.97 against the News app, so "open new tab on
// personal" opened News before the rest of the sentence arrived.
for said in ["open new", "open ne", "open sch"] {
    let r = resolve(said)
    check("\"\(said)\" matches nothing yet", r == nil, r?.macro.name ?? "nil")
}
for (said, name) in [("open chrome", "Chrome"), ("open safari", "Safari"),
                     ("open audacity", "Audacity"), ("open xcode", "Xcode"),
                     ("open google chrome", "Chrome"), ("open prism launcher", "Minecraft")] {
    let r = resolve(said)
    check("\"\(said)\" still resolves to \(name)", r?.macro.name == name, r?.macro.name ?? "nil")
}

print("\n=== url prefixes used to spot an open tab ===")
let gmailPrefixes = Browser.matchPrefixes(for: "https://mail.google.com")
check("covers https and www variants",
      gmailPrefixes.contains("https://mail.google.com")
        && gmailPrefixes.contains("https://www.mail.google.com"), "\(gmailPrefixes.count) prefixes")
let ytPrefixes = Browser.matchPrefixes(for: "https://www.youtube.com")
check("strips www so a bare host still matches",
      ytPrefixes.contains("https://youtube.com"), ytPrefixes.joined(separator: " "))
let pathed = Browser.matchPrefixes(for: "https://school.schoology.com/home")
check("keeps a path when one is given",
      pathed.allSatisfy { $0.hasSuffix("/home") }, pathed.joined(separator: " "))
check("a non-url yields nothing", Browser.matchPrefixes(for: "not a url").isEmpty)

print("\n=== which open tab counts as the same page ===")
for (tab, target, want) in [
    ("https://mail.google.com/mail/u/0/#inbox", "https://mail.google.com", true),
    ("https://www.youtube.com/watch?v=abc", "https://www.youtube.com", true),
    ("https://youtube.com/feed", "https://www.youtube.com", true),
    ("https://school.schoology.com/home", "https://school.schoology.com", true),
    ("https://drive.google.com/drive/my-drive", "https://mail.google.com", false),
    ("https://example.com/a/b", "https://example.com/a", true),
    ("https://example.com/z", "https://example.com/a", false),
] {
    check("\(tab) ~ \(target) = \(want)", Browser.tabMatches(tab, target: target) == want)
}

print("\n=== reminders: capturing what you said ===")
let reminderCases: [(String, String)] = [
    ("remind me to call mom", "call mom"),
    ("jarvis remind me to buy milk", "buy milk"),
    ("add a reminder to water the plants", "water the plants"),
    ("remember to lock the door", "lock the door"),
    ("set a reminder to email Coach Dan", "email Coach Dan"),
    ("remind me to check in with work", "check in with work"),
]
for (said, payload) in reminderCases {
    let r = resolve(said)
    check("\"\(said)\" -> \"\(payload)\"", r?.macro.kind == .reminder && r?.payload == payload,
          "\(r?.macro.name ?? "nil") payload=\(r?.payload ?? "nil")")
}

print("\n=== reminders: spoken date and time, end to end ===")
let spoken: [(String, String, Bool)] = [
    ("remind me september 3rd at 10am to brush my teeth", "brush my teeth", true),
    ("remind me tomorrow at 5pm to call mom", "call mom", true),
    ("remind me to take out the trash tomorrow", "take out the trash", true),
    ("remind me on friday at 9am to email coach dan", "email coach dan", true),
    ("jarvis remind me at noon to eat lunch", "eat lunch", true),
    ("remind me to buy milk", "buy milk", false),
]
for (said, title, hasDate) in spoken {
    guard let r = resolve(said), r.macro.kind == .reminder, let payload = r.payload else {
        check("\"\(said)\"", false, "did not resolve as a reminder"); continue
    }
    let (got, due) = Reminders.parse(payload)
    check("\"\(said)\" -> \"\(title)\"\(hasDate ? " + date" : "")",
          got.lowercased() == title.lowercased() && (due != nil) == hasDate,
          "title=\"\(got)\" due=\(due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none")")
}

print("\n=== regression: half-finished dictation is not a reminder ===")
// "remind me in" used to become a reminder titled "in", because the engine
// fires on partial transcripts and that partial already parsed.
for said in ["remind me in", "remind me to", "remind me at", "remind me on the"] {
    let r = resolve(said)
    check("\"\(said)\" is not yet a reminder", r?.macro.kind != .reminder,
          "\(r?.macro.name ?? "nothing") payload=\(r?.payload ?? "nil")")
}

print("\n=== relative times, end to end ===")
for (said, title, mins) in [("remind me in 30 minutes to brush my teeth", "brush my teeth", 30),
                            ("remind me in an hour to call mom", "call mom", 60),
                            ("remind me in half an hour to leave", "leave", 30),
                            ("jarvis remind me in 15 minutes to flip the laundry", "flip the laundry", 15)] {
    guard let r = resolve(said), r.macro.kind == .reminder, let payload = r.payload else {
        check("\"\(said)\"", false, "did not resolve as a reminder"); continue
    }
    let (got, due) = Reminders.parse(payload)
    let away = due.map { Int(($0.timeIntervalSinceNow / 60).rounded()) }
    check("\"\(said)\" -> \"\(title)\" in ~\(mins) min",
          got.lowercased() == title && (away.map { abs($0 - mins) <= 1 } ?? false),
          "title=\"\(got)\" ~\(away.map(String.init) ?? "none") min")
}

print("\n=== regression: a trigger phrase must not eat the next word ===")
// "remind me to" is a substring of "remind me tomorrow" — matching by substring
// silently swallowed the date word and scheduled things for today.
for (said, expected) in [("remind me tomorrow at 5pm to call mom", "tomorrow at 5pm to call mom"),
                         ("remind me tonight to take the bins out", "tonight to take the bins out"),
                         ("remind me today to stretch", "today to stretch")] {
    let r = resolve(said)
    check("\"\(said)\" keeps its first word", r?.payload == expected, r?.payload ?? "nil")
}
if let r = resolve("remind me tomorrow at 5pm to call mom"), let payload = r.payload {
    let (_, due) = Reminders.parse(payload)
    let isTomorrow = due.map { Calendar.current.isDateInTomorrow($0) } ?? false
    check("it lands tomorrow, not today", isTomorrow,
          due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none")
}

print("\n=== reminders: nothing to remind about ===")
for said in ["remind me", "remember", "open chrome"] {
    let r = resolve(said)
    check("\"\(said)\" is not an empty reminder", r?.macro.kind != .reminder || r?.payload != nil,
          "\(r?.macro.name ?? "nil") payload=\(r?.payload ?? "nil")")
}

print("\n=== reminders: title and due date ===")
for (text, title, hasDate) in [("call mom tomorrow at 5pm", "call mom", true),
                               ("buy milk", "buy milk", false),
                               ("take out the trash tomorrow", "take out the trash", true),
                               ("email Coach Dan on Friday at 9am", "email Coach Dan", true)] {
    let (got, due) = Reminders.parse(text)
    check("\"\(text)\" -> title \"\(title)\", date \(hasDate)",
          got.lowercased() == title.lowercased() && (due != nil) == hasDate,
          "title=\"\(got)\" due=\(due.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none")")
}

print("\n\(failures == 0 ? "ALL FEATURE TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
