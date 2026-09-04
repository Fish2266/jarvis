import Foundation

// Everything that produces an exact answer without asking the model: sums,
// conversions, durations, volume and transport words, and the search URL.
//
// These exist because a language model is confidently wrong at precisely this
// sort of thing — it invents times, fumbles arithmetic and has favourite
// "random" numbers — so each one has to be right on its own.

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

print("=== sums are worked out, not guessed ===")
let sums: [(String, String)] = [
    ("whats 12 times 8", "96"),
    ("what is 2 plus 2", "4"),
    ("whats 100 divided by 4", "25"),
    ("what is 15 percent of 240", "36"),
    ("whats 20 percent off 50", "40"),
    ("what is 8 percent on 25", "27"),
    ("whats 15% of 240", "36"),
    ("calculate 3.5 plus 1.25", "4.75"),
    ("whats 2 to the power of 10", "1024"),
    ("what is twelve times eight", "96"),
    ("whats 1,000 plus 500", "1500"),
    ("what is 5 x 5", "25"),
    ("whats -3 plus 10", "7"),
    ("what is (3 + 4) * 2", "14"),
    ("whats 9 divided by 2", "4.5"),
]
for (said, want) in sums {
    let got = Calc.answer(for: said)
    check("\"\(said)\" = \(want)", got?.hasPrefix(want + ",") == true, got ?? "nil")
}

print("\n=== and refused when it isn't a sum ===")
// A decimal point survives here and nowhere else in the app: the ordinary
// normalizer turns "3.5 plus 1.25" into "3 5 plus 1 25", which is a hundred
// and sixty rather than four and three quarters.
check("a decimal point is not a word boundary", Calc.evaluate("3.5 plus 1.25") == 4.75)
// Spaces are kept for the same reason: without them "12 8 plus 3" is "128+3".
check("two numbers with no operator are not one number",
      Calc.answer(for: "whats 12 8 plus 3") == nil)
for said in ["whats 7", "what's five plus", "how do i sleep better",
             "what is the capital of france", "tell me a joke", "how are you",
             "whats 10 divided by 0", "open chrome"] {
    check("\"\(said)\" has no sum", Calc.answer(for: said) == nil, Calc.answer(for: said) ?? "nil")
}

print("\n=== conversions ===")
let conversions: [(String, String)] = [
    ("how many kilometers in 5 miles", "8.0467 kilometres"),
    ("convert 20 celsius to fahrenheit", "68 degrees Fahrenheit"),
    ("how many ounces in a pound", "16 ounces"),
    ("how many ounces are in a pound", "16 ounces"),
    ("how many minutes in an hour", "60 minutes"),
    ("how many minutes in 3 hours", "180 minutes"),
    ("convert 2.5 miles to km", "4.0234 kilometres"),
    ("how many cups in a gallon", "16 cups"),
]
for (said, want) in conversions {
    let got = Calc.conversion(for: said)
    check("\"\(said)\"", got?.hasPrefix(want) == true, got ?? "nil")
}
for said in ["5 miles in kilograms", "whats the weather", "how many cats in a dog"] {
    check("\"\(said)\" converts nothing", Calc.conversion(for: said) == nil,
          Calc.conversion(for: said) ?? "nil")
}

print("\n=== timer durations ===")
let durations: [(String, TimeInterval)] = [
    ("set a timer for 5 minutes", 300),
    ("timer for 30 seconds", 30),
    ("set a timer for an hour", 3600),
    // "half an hour" is thirty minutes. Reading the article as the number one
    // made it sixty.
    ("set a timer for half an hour", 1800),
    // The trailing half belongs to the unit just used.
    ("timer for an hour and a half", 5400),
    // ...and adds to the amount rather than replacing it.
    ("set a timer for two and a half hours", 9000),
    ("set a 10 minute timer", 600),
    ("set a timer for twenty five minutes", 1500),
    ("timer for 1 hour 30 minutes", 5400),
    ("set a timer for a couple of minutes", 120),
    ("timer for 90 seconds", 90),
    ("set a timer for a minute", 60),
]
for (said, want) in durations {
    let got = Countdown.intent(in: said)
    check("\"\(said)\" = \(Int(want))s", got == .set(want), "\(got)")
}

print("\n=== and the other things you say about a timer ===")
for said in ["cancel the timer", "stop the timer", "forget the timer"] {
    check("\"\(said)\"", Countdown.intent(in: said) == .cancel, "\(Countdown.intent(in: said))")
}
for said in ["how long is left", "how much is left on the timer", "time left on the timer"] {
    check("\"\(said)\"", Countdown.intent(in: said) == .report, "\(Countdown.intent(in: said))")
}
for said in ["timer", "set a timer", "set a timer for 5"] {
    // "for 5" has no unit, and guessing between five seconds and five minutes
    // is how a five-second timer runs for five minutes.
    check("\"\(said)\" needs a length", Countdown.intent(in: said) == .needsDuration,
          "\(Countdown.intent(in: said))")
}
check("a day-long kitchen timer is a misheard sentence",
      Countdown.duration(in: "timer for 400 hours") == nil)

print("\n=== a running timer reads back sensibly ===")
for (seconds, clock, spoken) in [(45.0, "0:45", "45 seconds"),
                                 (90.0, "1:30", "1 minute and 30 seconds"),
                                 (300.0, "5:00", "5 minutes"),
                                 (3600.0, "1:00:00", "1 hour"),
                                 (5400.0, "1:30:00", "1 hour and 30 minutes")] {
    check("\(Int(seconds))s reads \(clock) / \(spoken)",
          Countdown.clock(seconds) == clock && Countdown.spoken(seconds) == spoken,
          "\(Countdown.clock(seconds)) / \(Countdown.spoken(seconds))")
}

print("\n=== volume words ===")
let volumes: [(String, SystemAudio.Change)] = [
    ("turn it up", .up(SystemAudio.step)),
    ("louder", .up(SystemAudio.step)),
    ("volume down", .down(SystemAudio.step)),
    ("quieter", .down(SystemAudio.step)),
    ("mute", .mute),
    ("be quiet", .mute),
    ("unmute", .unmute),
    ("set the volume to 40", .set(40)),
    ("volume 60 percent", .set(60)),
    ("volume to twenty five percent", .set(25)),
    ("max volume", .set(100)),
    ("how loud is it", .report),
]
for (said, want) in volumes {
    check("\"\(said)\"", SystemAudio.change(for: said) == want,
          "\(String(describing: SystemAudio.change(for: said)))")
}
// Whole words, not substrings: "up" lives inside "upload".
for said in ["upload the file", "open chrome", "play track 5"] {
    check("\"\(said)\" changes nothing", SystemAudio.change(for: said) == nil,
          "\(String(describing: SystemAudio.change(for: said)))")
}
// An explicit level beats a direction, or "volume up to 40" would step by ten.
check("a named level wins over a direction",
      SystemAudio.change(for: "turn the volume up to 40") == .set(40))

print("\n=== transport words ===")
let transports: [(String, MediaKeys.Transport)] = [
    ("next track", .next), ("skip", .next), ("next song", .next),
    ("previous track", .previous), ("previous song", .previous), ("go back", .previous),
    ("pause", .playPause), ("resume", .playPause), ("play pause", .playPause),
]
for (said, want) in transports {
    check("\"\(said)\"", MediaKeys.transport(for: said) == want,
          "\(String(describing: MediaKeys.transport(for: said)))")
}
// "play" is inside "player" and "display"; a command that pauses your music
// because you said "display" is worse than one that misses.
for said in ["display the thing", "player", "open chrome", "upload it"] {
    check("\"\(said)\" is not a transport", MediaKeys.transport(for: said) == nil,
          "\(String(describing: MediaKeys.transport(for: said)))")
}

print("\n=== the search URL ===")
check("a plain query is appended",
      WebSearch.url(for: "tide times")?.absoluteString
        == "https://www.google.com/search?q=tide%20times")
// Every one of these is legal in a URL and every one changes what the search
// engine receives, so each has to be escaped rather than passed through.
for (query, escaped) in [("c# vs f#", "%23"), ("a&b", "%26"), ("1+1", "%2B"),
                         ("x=y", "%3D"), ("a/b", "%2F")] {
    let text = WebSearch.url(for: query)?.absoluteString ?? ""
    check("\"\(query)\" escapes to \(escaped)", text.contains(escaped), text)
}
check("an empty query has no URL", WebSearch.url(for: "   ") == nil)
check("a placeholder puts the words where they belong",
      WebSearch.url(for: "cats", engine: "https://x.test/%s/results")?.absoluteString
        == "https://x.test/cats/results")
check("an empty engine falls back to Google",
      WebSearch.url(for: "cats", engine: "")?.absoluteString.hasPrefix("https://www.google.com") == true)
check("a long query is shortened for the headline",
      WebSearch.headline(for: String(repeating: "word ", count: 40)).count < 64)

print("\n=== questions the Mac can answer itself ===")
for said in ["how much battery do i have", "whats my battery level"] {
    check("\"\(said)\" is answered locally", Questions.localAnswer(for: said) != nil)
}
for said in ["whats my ip address", "am i online"] {
    check("\"\(said)\" is answered locally", Questions.localAnswer(for: said) != nil)
}
check("uptime is answered locally", Questions.localAnswer(for: "whats my uptime") != nil)
check("free space is answered, but off the main thread",
      Questions.deferredAnswer(for: "how much space is left") != nil)
check("free space is not an instant answer",
      Questions.localAnswer(for: "how much space is left") == nil)
check("an ordinary question has neither",
      Questions.localAnswer(for: "why is the sky blue") == nil
        && Questions.deferredAnswer(for: "why is the sky blue") == nil)

print("\n=== chance, which a model is bad at ===")
// A model asked for a coin flip has favourites. Over a hundred flips both
// faces must actually turn up.
var faces = Set<String>()
var rolls = Set<String>()
for _ in 0..<200 {
    if let flip = Questions.chanceAnswer("flip a coin") { faces.insert(flip) }
    if let roll = Questions.chanceAnswer("roll a die") { rolls.insert(roll) }
}
check("a coin lands both ways", faces.count == 2, faces.sorted().joined(separator: " / "))
check("a die uses all six faces", rolls.count == 6, "\(rolls.count) distinct")
check("a d20 goes past six",
      (0..<200).compactMap { _ in Questions.chanceAnswer("roll a d20") }
        .contains { !$0.hasPrefix("1,") && Int($0.prefix(2).trimmingCharacters(
            in: CharacterSet(charactersIn: ", "))) ?? 0 > 6 })
check("a range is honoured",
      (0..<200).allSatisfy {  _ in
          guard let a = Questions.chanceAnswer("pick a number between 5 and 7"),
                let n = Int(a.prefix(while: { $0.isNumber })) else { return false }
          return (5...7).contains(n)
      })
check("an ordinary sentence rolls nothing", Questions.chanceAnswer("how are you") == nil)

// Whole words, not substrings. Each of these contains "die", "coin" or "roll"
// inside a longer word, and each of them used to come back with a number.
for said in ["what should i eat on a diet", "what a coincidence", "how does payroll work",
             "what is a game controller", "whats a trolley problem",
             "how do dietary supplements work", "whats the rolling average"] {
    check("\"\(said)\" is not a dice roll", Questions.chanceAnswer(said) == nil,
          Questions.chanceAnswer(said) ?? "nil")
}
// ...and the real ones still work.
for said in ["flip a coin", "roll a die", "roll the dice", "heads or tails",
             "roll two dice", "roll a d20"] {
    check("\"\(said)\" still answers", Questions.chanceAnswer(said) != nil)
}

print("\n=== these are orders, but they still want an answer ===")
for said in ["flip a coin", "roll a die", "pick a number between 1 and 10"] {
    check("\"\(said)\" reaches the answer path", Questions.looksLikeQuestion(said))
}

print("\n=== the time somewhere else ===")
let noon = Date()
check("a named city is answered in its own zone",
      Questions.worldClock("what time is it in tokyo", now: noon)?.contains("Tokyo") == true,
      Questions.worldClock("what time is it in tokyo", now: noon) ?? "nil")
check("a two-word city works too",
      Questions.worldClock("what time is it in new york", now: noon)?.contains("New York") == true,
      Questions.worldClock("what time is it in new york", now: noon) ?? "nil")
check("no city means the local clock",
      Questions.worldClock("what time is it", now: noon) == nil)
check("a city that isn't one means the local clock",
      Questions.worldClock("what time is it in the morning", now: noon) == nil)
check("the local clock still answers plainly",
      Questions.localAnswer(for: "what time is it")?.contains(":") == true)

print("\n=== spoken lists are held to what an ear can hold ===")
check("one item reads as one",
      Agenda.summarize(["buy milk"], noun: "reminder").hasPrefix("One reminder"))
check("three read out in full",
      Agenda.summarize(["a", "b", "c"], noun: "reminder").contains("a, b and c"))
check("more than three are counted, not recited",
      Agenda.summarize(["a", "b", "c", "d", "e"], noun: "reminder").contains("2 more"))
check("nothing reads as nothing",
      Agenda.summarize([], noun: "reminder") == "Nothing, sir.")
check("blank titles don't become empty items",
      Agenda.summarize(["  ", "buy milk"], noun: "reminder").hasPrefix("One reminder"))

print("\n=== the HUD's level curve ===")
check("silence draws nothing", HUD.voiceScale(0) == 0)
check("a loud frame fills it", HUD.voiceScale(0.05) == 1)
check("it never overflows", HUD.voiceScale(10) == 1)
check("quiet speech is still visible", HUD.voiceScale(0.005) > 0.2)
check("the curve is monotonic",
      stride(from: Float(0), to: 0.1, by: 0.002).allSatisfy {
          HUD.voiceScale($0) <= HUD.voiceScale($0 + 0.002)
      })

print(failures == 0 ? "\nALL ANSWER TESTS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
