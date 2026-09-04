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

print("\n=== where a window goes ===")
let placements: [(String, WindowManager.Placement)] = [
    ("snap left", .left), ("put it on the right", .right),
    ("left half", .left), ("right half", .right),
    ("top half", .top), ("bottom half", .bottom),
    ("top left", .topLeft), ("bottom right", .bottomRight),
    ("upper right", .topRight), ("lower left", .bottomLeft),
    ("maximize", .maximize), ("maximise", .maximize), ("fill the screen", .maximize),
    ("full screen", .fullScreen), ("centre the window", .center),
    ("center the window", .center),
]
for (said, want) in placements {
    check("\"\(said)\"", WindowManager.placement(for: said) == want,
          "\(String(describing: WindowManager.placement(for: said)))")
}
// "top left" must never be read as the bare "left", or every corner would
// become a half.
check("a corner beats a side",
      WindowManager.placement(for: "put it top left") == .topLeft)
// Whole words: "left" is inside "leftover", "top" inside "laptop".
for said in ["put the laptop down", "i have leftovers", "open chrome"] {
    check("\"\(said)\" moves nothing", WindowManager.placement(for: said) == nil,
          "\(String(describing: WindowManager.placement(for: said)))")
}
// Two placements keep the window's own size rather than a fraction of the screen.
check("centre and full screen have no rectangle",
      WindowManager.Placement.center.fractions == nil
        && WindowManager.Placement.fullScreen.fractions == nil)
// Every fraction has to be inside the screen and non-empty, or a window would
// land off the edge or with no size at all.
for placement in [WindowManager.Placement.left, .right, .top, .bottom, .topLeft,
                  .topRight, .bottomLeft, .bottomRight, .maximize] {
    guard let (x, y, w, h) = placement.fractions else { continue }
    check("\(placement.label) stays on screen",
          x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1.0001 && y + h <= 1.0001,
          "\(x) \(y) \(w) \(h)")
}

print("\n=== staying awake ===")
check("a bare request holds indefinitely",
      KeepAwake.intent(in: "stay awake") == .hold(nil))
check("a length is honoured",
      KeepAwake.intent(in: "stay awake for two hours") == .hold(7200))
check("half an hour is thirty minutes",
      KeepAwake.intent(in: "keep awake for half an hour") == .hold(1800))
// Cancel is read before the length, so a release that names one is still a
// release — the same ordering the timer needs.
check("stopping is stopping", KeepAwake.intent(in: "stop staying awake") == .release)
check("letting it sleep is stopping",
      KeepAwake.intent(in: "you can let it sleep now") == .release)
check("asking is asking", KeepAwake.intent(in: "how long is left on that") == .report)
check("an unheld Mac describes itself", KeepAwake.describe(nil) == "until you say otherwise")

print("\n=== the clipboard ===")
// This is the real system pasteboard, so whatever was on it is put back at the
// end. Running the tests should not cost you the thing you had copied.
let clipboardBefore = Clipboard.read()
check("copying keeps what was said", Clipboard.copy("buy milk and eggs"))
check("...and reads it back", Clipboard.read() == "buy milk and eggs")
check("an empty dictation throws nothing away", Clipboard.copy("   ") == false)
check("what it had is still there", Clipboard.read() == "buy milk and eggs")
check("a short clipboard is read out",
      Clipboard.spokenSummary().contains("buy milk and eggs"))
// Reading four hundred words aloud is not an answer to "what's on my clipboard".
_ = Clipboard.copy(Array(repeating: "word", count: 300).joined(separator: " "))
let long = Clipboard.spokenSummary()
check("a long one is described, not recited",
      long.contains("300 words") && long.count < 220, "\(long.count) chars")
check("the headline is shortened too",
      Clipboard.headline(for: String(repeating: "x", count: 200)).count < 60)
if let clipboardBefore { _ = Clipboard.copy(clipboardBefore) }
check("the clipboard is left as it was found", Clipboard.read() == clipboardBefore,
      clipboardBefore == nil ? "was empty, and an empty copy is refused" : "restored")

print("\n=== how long until something ===")
let noonToday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
check("a time later today counts in minutes",
      Questions.untilAnswer("how long until 3pm", now: noonToday)?.contains("hour") == true,
      Questions.untilAnswer("how long until 3pm", now: noonToday) ?? "nil")
check("a date counts in days",
      Questions.untilAnswer("how many days until december 25", now: noonToday) != nil)
check("an ordinary question is not a countdown",
      Questions.untilAnswer("why is the sky blue", now: noonToday) == nil)
check("an opener with no date in it answers nothing",
      Questions.untilAnswer("how long until i finish", now: noonToday) == nil)

// The opener has to be taken off before the date parser sees it. Handed
// "until december 25" whole, NSDataDetector swallows the word "until" and
// answers with *today* at four in the afternoon — so "how many days until
// Christmas" came back as an hour and a half. It matched, it returned a date,
// and the date was nonsense.
let sept4 = Calendar.current.date(from: DateComponents(
    year: 2026, month: 9, day: 4, hour: 10, minute: 36))!
let countdowns: [(String, String)] = [
    ("how many days until christmas", "112 days"),
    ("how long until christmas", "112 days"),
    ("how many days until xmas", "112 days"),
    ("how many days until december 25", "112 days"),
    ("how many days until halloween", "57 days"),
    ("how many days until new years", "119 days"),
    ("how many days until new years eve", "118 days"),
    ("how many days until valentines day", "163 days"),
]
for (said, want) in countdowns {
    let got = Questions.untilAnswer(said, now: sept4)
    check("\"\(said)\" = \(want)", got?.hasPrefix(want) == true, got ?? "nil")
}
// Counted in calendar days, not 24-hour blocks: Christmas is the same number of
// sleeps away whether you ask at breakfast or at midnight.
let lateSept4 = Calendar.current.date(from: DateComponents(
    year: 2026, month: 9, day: 4, hour: 23, minute: 55))!
check("the day count doesn't shift with the time of day",
      Questions.untilAnswer("how many days until christmas", now: sept4)
        == Questions.untilAnswer("how many days until christmas", now: lateSept4))
// A holiday already gone this year rolls to the next.
let boxingDay = Calendar.current.date(from: DateComponents(
    year: 2026, month: 12, day: 26, hour: 12))!
check("a passed holiday rolls to next year",
      Questions.untilAnswer("how many days until halloween", now: boxingDay)?
        .hasPrefix("309 days") == true,
      Questions.untilAnswer("how many days until halloween", now: boxingDay) ?? "nil")
// "How long to" is not an opener, or "how long to boil an egg" would be one.
check("\"how long to boil an egg\" is not a countdown",
      Questions.untilAnswer("how long to boil an egg", now: sept4) == nil)
check("a holiday the table hasn't got falls through to the model",
      Questions.untilAnswer("how many days until my birthday", now: sept4) == nil)

print("\n=== asking for it again ===")
for said in ["say that again", "repeat that", "what was that", "one more time",
             "what did you say", "come again"] {
    check("\"\(said)\" asks for a repeat", Questions.isRepeatRequest(said))
    check("\"\(said)\" reaches the answer path", Questions.looksLikeQuestion(said))
}
for said in ["what time is it", "open chrome", "how are you"] {
    check("\"\(said)\" is not a repeat", !Questions.isRepeatRequest(said))
}

print("\n=== the HUD's level curve ===")
// The reticle's dot animates between levels rather than snapping to each one,
// so it needs to know how long the gap is. Levels arrive every 2048 samples.
check("the level interval is a sane default before the engine starts",
      HUD.levelInterval > 0.02 && HUD.levelInterval < 0.1,
      String(format: "%.1f ms", HUD.levelInterval * 1000))
HUD.audioRate = 48_000
check("2048 samples at 48 kHz is 43 ms",
      abs(2048.0 / 48_000 - 0.04267) < 0.0005)

// The dot used to be written straight to the layer with animations off, once
// per level — twenty-three discrete steps a second on a screen refreshing sixty
// or more, which reads as a jitter. Two things fixed it: Core Animation now
// interpolates between levels, and the level itself is filtered rather than
// snapped to. The second half is measurable.
//
// A synthetic speech envelope: a slow swell with frame-to-frame noise on it,
// which is what a real RMS looks like.
var seed: UInt64 = 0x9E3779B97F4A7C15
func noise() -> Double {          // deterministic, so the test cannot flake
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double((seed >> 33) % 1000) / 1000.0
}
let raw: [Float] = (0..<400).map { i in
    let swell = (sin(Double(i) / 18.0) + 1) / 2
    return Float(max(0, min(0.05, (swell * 0.035 + noise() * 0.018))))
}
/// Total frame-to-frame change in direction — how much the motion stutters.
func jerk(_ values: [CGFloat]) -> CGFloat {
    guard values.count > 2 else { return 0 }
    var total: CGFloat = 0
    for i in 2..<values.count {
        total += abs((values[i] - values[i - 1]) - (values[i - 1] - values[i - 2]))
    }
    return total
}
let unsmoothed = raw.map { HUD.voiceScale($0) }
var running: CGFloat = 0
let smoothed = raw.map { sample -> CGFloat in
    running = HUD.smoothed(running, towards: HUD.voiceScale(sample))
    return running
}
let before = jerk(unsmoothed), after = jerk(smoothed)
check("filtering the level cuts the stutter by more than half",
      after < before * 0.5, String(format: "jerk %.1f -> %.1f", before, after))
// ...without flattening it into something that no longer follows the voice.
check("and it still follows the swell",
      (smoothed.max() ?? 0) > (unsmoothed.max() ?? 0) * 0.6,
      String(format: "peak %.2f vs %.2f", smoothed.max() ?? 0, unsmoothed.max() ?? 0))
check("a rise is followed faster than a fall", HUD.voiceAttack > HUD.voiceRelease)
check("neither is a snap", HUD.voiceAttack < 1 && HUD.voiceRelease > 0)
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
