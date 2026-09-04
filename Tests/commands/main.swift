import Foundation

// The new commands, resolved the same way every other one is — and, more to the
// point, the old commands still resolving the way they always did. Every new
// phrase is a new chance to shadow an existing one, so most of what is checked
// here is that nothing moved.

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// Someone's existing commands, plus the built-ins a new version hands them.
// That is exactly what `MacroStore.installNewBuiltins` produces, so this is the
// arrangement most people will actually be running.
let saved = try! JSONDecoder().decode(
    [Macro].self, from: try! Data(contentsOf: here.appendingPathComponent("../questions/macros.json")))
let macros = saved + Macro.added
_ = AppIndex.shared.refresh()

func resolve(_ s: String) -> Resolution? { Resolver.resolveFast(transcript: s, macros: macros) }
func named(_ s: String) -> String { resolve(s)?.macro.name ?? "nothing" }

print("=== the new commands resolve ===")
let expected: [(String, String)] = [
    ("set a timer for five minutes", "Timer"),
    ("start a timer for 30 seconds", "Timer"),
    ("set a ten minute timer", "Timer"),
    ("cancel the timer", "Timer"),
    ("stop the timer", "Timer"),
    ("how long is left", "Timer"),
    ("turn it up", "Volume"),
    ("turn the volume down", "Volume"),
    ("mute", "Volume"),
    ("jarvis mute", "Volume"),
    ("unmute", "Volume"),
    ("louder", "Volume"),
    ("how loud is it", "Volume"),
    ("next track", "Playback"),
    ("previous track", "Playback"),
    ("pause it", "Playback"),
    ("pause the music", "Playback"),
    ("skip this", "Playback"),
    ("resume", "Playback"),
    ("snap left", "Window"),
    ("right half", "Window"),
    ("maximize", "Window"),
    ("full screen", "Window"),
    ("stay awake", "Stay awake"),
    ("keep the mac awake", "Stay awake"),
    ("caffeinate", "Stay awake"),
    ("stop staying awake", "Stay awake"),
    ("lock the screen", "Lock"),
    ("jarvis lock the screen", "Lock"),
    ("lock my mac", "Lock"),
    ("whats on my calendar", "My day"),
    ("whats my next meeting", "My day"),
    ("my schedule", "My day"),
    ("what are my reminders", "My reminders"),
    ("whats on my list", "My reminders"),
    ("tomorrows forecast", "Forecast"),
    ("hows tomorrow looking", "Forecast"),
    ("will it rain tomorrow", "Forecast"),
]
for (said, want) in expected {
    check("\"\(said)\" -> \(want)", named(said) == want, named(said))
}

print("\n=== searching captures what follows the phrase ===")
for (said, query) in [("search for how to poach an egg", "how to poach an egg"),
                      ("look up the offside rule", "the offside rule"),
                      ("google for swift concurrency", "swift concurrency"),
                      ("search the web for tide times", "tide times")] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.kind == .search && r?.payload == query,
          "\(r?.macro.name ?? "nothing") payload=\(r?.payload ?? "-")")
}

print("\n=== nothing the new commands added has shadowed an old one ===")
// Each of these is a phrase a new command could plausibly have stolen.
let unchanged: [(String, String)] = [
    // "google" is a Search-ish word and "chrome" is not a search query.
    ("google chrome", "Chrome"),
    ("open google chrome", "Chrome"),
    ("open chrome", "Chrome"),
    // "play" is a verb meaning open, which is why Playback has no bare "play".
    ("play minecraft", "Minecraft"),
    ("play the craft", "Minecraft"),
    // A reminder that happens to mention searching is still a reminder.
    ("remind me to look up the recipe", "Reminder"),
    ("remind me to buy milk", "Reminder"),
    // The weather command answers to "forecast" and keeps it.
    ("forecast", "Weather"),
    ("whats the weather", "Weather"),
    ("whats it like outside", "Weather"),
    // Old favourites.
    ("start up the craft", "Minecraft"),
    ("wake up daddys home", "Claude"),
    ("open my email", "Gmail"),
    ("open a new tab", "Chrome"),
]
for (said, want) in unchanged {
    check("\"\(said)\" is still \(want)", named(said) == want, named(said))
}

print("\n=== copying captures what follows the phrase ===")
for (said, kept) in [("copy that down 0 7 1 double 4 double 6",
                      "0 7 1 double 4 double 6"),
                     ("note this down the meeting moved to thursday",
                      "the meeting moved to thursday")] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.kind == .clipboard && r?.payload == kept,
          "\(r?.macro.name ?? "nothing") payload=\(r?.payload ?? "-")")
}

print("\n=== the clock still belongs to the clock ===")
// A bare "timer" is one typo from "time", and the coverage count gives a
// one-word phrase full marks for a single fuzzy word — so every sentence
// containing "time" fired the timer, and "what time is it" stopped being
// answered from the system clock. Every one of these shipped broken once.
for said in ["what time is it", "whats the time", "what time is it in tokyo",
             "do you have the time", "how much time do i have",
             "time for a break", "what a waste of time", "what day is it",
             "what time should i go to sleep"] {
    check("\"\(said)\" is not a command", resolve(said) == nil, named(said))
}

print("\n=== nor does one typo make a command ===")
// Same failure, different words: "cause" is one edit from "pause", "ship" from
// "skip", "mate" from "mute". A phrase of two words cannot be reached this way,
// because the second word has to be there as well.
for said in ["whats the cause of that", "how big is the ship",
             "how do i sleep better", "tell me about sleep",
             "is my mac asleep", "how much space is left"] {
    check("\"\(said)\" is not a command", resolve(said) == nil, named(said))
}

print("\n=== questions that merely sound like commands ===")
// "how much time is left" was a Timer phrase until it turned out to be one word
// from "how much space is left", which is a question about the disk.
for said in ["how much space is left", "how much disk space do i have",
             "how much storage is left"] {
    check("\"\(said)\" is not the timer", resolve(said)?.macro.kind != .timer, named(said))
}
for said in ["am i online", "whats my ip address", "how much battery do i have"] {
    check("\"\(said)\" is not a command", resolve(said) == nil, named(said))
}

print("\n=== quitting is a verb, not a command ===")
for said in ["quit chrome", "close chrome", "quit out of chrome", "kill chrome",
             "jarvis quit chrome", "quit chrome now"] {
    let r = resolve(said)
    check("\"\(said)\"", r?.macro.name == "Chrome" && r?.quitTarget == true
            && r?.macro.kind.canBeQuit == true,
          "\(r?.macro.name ?? "nothing") quit=\(r?.quitTarget.description ?? "-")")
}
for said in ["open chrome", "bring over chrome", "start up the craft"] {
    check("\"\(said)\" is not a quit", resolve(said)?.quitTarget == false,
          "\(named(said)) quit=\(resolve(said)?.quitTarget.description ?? "-")")
}
// The flag can be set on something with no process to end. It is ignored there
// rather than failing, exactly as "gimme the weather" ignores being brought.
check("quitting a non-app is ignored, not obeyed",
      ActionKind.weather.canBeQuit == false && ActionKind.url.canBeQuit == false)

print("\n=== locking has the same guards sleeping does ===")
for said in ["whats the lock screen shortcut", "remind me to lock the door",
             "how do i lock my screen faster", "open lock", "launch lock",
             "bring over lock", "tell me about lock screens"] {
    check("\"\(said)\" does not lock", resolve(said)?.macro.kind != .lock, named(said))
}
let offered = Resolver.candidates(macros: macros)
check("lock is withheld from the model's list",
      !offered.contains { $0.kind == .lock })
check("sleep is still withheld too", !offered.contains { $0.kind == .sleep })

print("\n=== every action kind is complete ===")
// A kind that captures text can never be reached by the fuzzy matcher, so one
// that also wants to be matched loosely would silently never fire.
for kind in ActionKind.allCases {
    check("\(kind.rawValue) is not both a capture and a sentence-reader",
          !(kind.capturesText && kind.readsSentence))
    check("\(kind.rawValue) has a title", !kind.title.isEmpty)
}
check("exactly two kinds need a near-exact phrase",
      ActionKind.allCases.filter(\.requiresExactPhrase).map(\.rawValue) == ["lock", "sleep"])
// A phrase of one word is reachable by a single fuzzy word match — the typo
// budget is one edit for anything four letters or longer — which is how "timer"
// was fired by "time" and "pause" by "cause". The shorter the word, the more
// ordinary words sit one edit away, so a built-in single-word phrase has to be
// long enough for that neighbourhood to be empty.
//
// "mute" is the one deliberate exception, and it is a judgement rather than an
// oversight: its neighbours are "mate", "mule" and "muse", none of which turn
// up in a sentence you would say to a computer, whereas "cause" and "ship" do.
let shortWordExceptions: Set<String> = ["mute"]
for macro in Macro.added {
    for phrase in macro.phrases where phrase.split(separator: " ").count == 1 {
        check("\(macro.name): \"\(phrase)\" is long enough to stand alone",
              phrase.count >= 6 || shortWordExceptions.contains(phrase), phrase)
    }
}
check("the kinds that speak for themselves say something",
      ActionKind.allCases.filter(\.handlesOwnReply).count >= 5)

print("\n=== built-ins reach an installation that predates them ===")
// The saved list has none of them; the new build must offer every one.
let existing = Set(saved.map { PhraseMatcher.normalize($0.name) })
for macro in Macro.added {
    check("\(macro.name) is new to a saved list",
          !existing.contains(PhraseMatcher.normalize(macro.name)))
}
check("no two built-ins share a name",
      Set(Macro.added.map(\.name)).count == Macro.added.count)
check("seeding a fresh install includes them all",
      Macro.added.allSatisfy { added in
          Macro.seeded().contains { $0.name == added.name } })

print("\n=== the store, against real persistence ===")
// Safe to use UserDefaults here: a command-line binary has no bundle
// identifier, so `UserDefaults.standard` is its own transient domain and
// cannot reach the installed app's preferences. Checked, not assumed.
check("the test binary has no bundle to collide with", Bundle.main.bundleIdentifier == nil)

let defaults = UserDefaults.standard
func wipe() {
    defaults.removeObject(forKey: "macros")
    defaults.removeObject(forKey: "builtinsInstalled")
}

// A fresh install seeds everything and records that it has done so, or the
// migration below would run on top of a list that already has them.
wipe()
let fresh = MacroStore.load()
check("a fresh install gets the built-ins",
      Macro.added.allSatisfy { added in fresh.contains { $0.name == added.name } })
check("and records them as installed",
      defaults.integer(forKey: "builtinsInstalled") == MacroStore.builtinCount)
check("loading again changes nothing", MacroStore.load().count == fresh.count)

// An installation that predates them: commands saved, no record of built-ins.
wipe()
MacroStore.save(saved)
defaults.removeObject(forKey: "builtinsInstalled")
let migrated = MacroStore.load()
check("an old installation keeps every command it had",
      saved.allSatisfy { old in migrated.contains { $0.name == old.name } })
check("and gains every built-in",
      Macro.added.allSatisfy { added in migrated.contains { $0.name == added.name } })
check("migrating twice does not duplicate them",
      MacroStore.load().count == migrated.count, "\(MacroStore.load().count) vs \(migrated.count)")

// A built-in you deleted stays deleted. The migration is keyed on how many
// have ever been offered, not on which are present.
var pruned = MacroStore.load()
pruned.removeAll { $0.name == "Timer" }
MacroStore.save(pruned)
check("a deleted built-in is not resurrected",
      !MacroStore.load().contains { $0.name == "Timer" })

// A command you wrote yourself is never shadowed by a built-in of that name.
wipe()
MacroStore.save(saved + [Macro(name: "Timer", phrases: ["my timer"], kind: .app, target: "/x")])
defaults.removeObject(forKey: "builtinsInstalled")
let withMine = MacroStore.load()
check("a hand-written command keeps its name to itself",
      withMine.filter { $0.name == "Timer" }.count == 1,
      "\(withMine.filter { $0.name == "Timer" }.count) called Timer")
check("and it is still mine",
      withMine.first { $0.name == "Timer" }?.kind == .app)

// One unreadable command must not take the rest with it. Decoding the array in
// one go meant a single bad element threw everything away and `load` quietly
// reseeded over the lot.
let goodJSON = try! JSONEncoder().encode(saved)
var array = try! JSONSerialization.jsonObject(with: goodJSON) as! [[String: Any]]
array[1]["kind"] = "somethingFromTheFuture"
let mixed = try! JSONSerialization.data(withJSONObject: array)
let salvaged = MacroStore.decode(mixed)
check("one unreadable command is skipped, not fatal",
      salvaged?.count == saved.count - 1, "\(salvaged?.count ?? -1) of \(saved.count)")
check("the readable ones come back intact",
      salvaged?.contains { $0.name == saved[0].name } == true)
check("wholly unreadable data still falls back to nil",
      MacroStore.decode(Data("not json at all".utf8)) == nil)

wipe()

print(failures == 0 ? "\nALL COMMAND TESTS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
