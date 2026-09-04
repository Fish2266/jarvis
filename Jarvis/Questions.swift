import Foundation

/// Spots a question so it can be answered instead of matched to a command.
///
/// Pure string work — a few microseconds — so it costs the app-opening path
/// nothing. It is also only consulted *after* the command resolver comes back
/// empty, which is why "what's the weather" still runs your Weather command
/// rather than going to the model.
enum Questions {

    /// First words that make something a question rather than an instruction.
    static let starters: Set<String> = [
        "what", "whats", "when", "whens", "where", "wheres", "why", "whys",
        "who", "whos", "whom", "whose", "how", "hows", "which",
        "is", "are", "was", "were", "am", "do", "does", "did",
        "can", "could", "should", "would", "will", "shall",
        "has", "have", "had", "if", "tell", "explain", "define",
    ]

    /// Openers that are questions even though the first word alone isn't.
    static let phrases = [
        "tell me", "do you", "can you", "could you", "what about", "how about",
        "give me", "i wonder", "any idea", "whats up", "help me", "i need help",
        "i need", "i want to know", "talk to me", "walk me through",
        "remind me what", "remind me how", "remind me who",
    ]

    /// Things you say *to* someone rather than ask *of* them.
    ///
    /// Matched against the whole sentence rather than as a prefix, and that
    /// matters: "hey" on its own is a greeting, but "hey, open chrome" is a
    /// command with a greeting bolted on the front, and a prefix match would
    /// send it to the model instead of opening Chrome. Being whole-sentence is
    /// also what lets these be one word, where the usual two-word floor applies.
    ///
    /// Deliberately absent: "good night" and its variants, which are how you put
    /// the Mac to sleep.
    static let greetings: Set<String> = [
        "hello", "hi", "hey", "yo", "howdy", "hiya", "greetings", "sup", "help",
        "hey there", "hi there", "hello there", "hello jarvis", "hi jarvis",
        "you there", "you awake", "you up", "are you there", "are you awake",
        "whats up", "whats new", "whats good", "what's happening", "whats happening",
        "how are you", "how are you doing", "how you doing", "hows it going",
        "how goes it", "how are things", "how have you been",
        "good morning", "good afternoon", "good evening", "morning", "afternoon",
        "evening", "thank you", "thanks", "thanks jarvis", "thank you jarvis",
        "cheers", "nice work", "good job", "well done", "youre the best",
    ]

    /// Openers that ask for something to be produced on the spot.
    ///
    /// These are imperatives rather than questions, so the starter list above
    /// would never catch them — and "flip a coin" reaching the app resolver and
    /// finding nothing is a worse answer than any answer.
    static let imperatives = [
        "flip a", "flip me", "toss a", "toss me", "roll a", "roll me", "roll the",
        "roll two", "pick a", "pick me", "choose a", "give me a",
        // Asking for the last line again is an order too, and one that has to
        // reach the answer path or there is nowhere for it to go.
        "say that", "say it", "say again", "repeat", "read my clipboard",
        "read the clipboard", "come again", "one more time",
    ]

    /// Questions with an exact answer the Mac already knows.
    ///
    /// Everything here is instant — microseconds — because it runs on the main
    /// thread while the HUD is animating. Anything that has to go to disk or
    /// the network belongs in `deferredAnswer` instead.
    ///
    /// `commands` is the names of your own commands, used only by "what can you
    /// do". It has a default so callers that don't care needn't pass it.
    static func localAnswer(for transcript: String, commands: [String] = []) -> String? {
        let text = PhraseMatcher.normalize(transcript)
        guard !text.isEmpty else { return nil }
        let now = Date()

        let timeAsks = ["what time is it", "whats the time", "what is the time",
                        "do you have the time", "got the time", "time is it",
                        "whats the time now", "what time is it now"]
        if timeAsks.contains(where: { text.contains($0) }) {
            // A named city wins over the local clock: "what time is it in tokyo"
            // contains "what time is it" and is not asking about here.
            if let elsewhere = worldClock(text, now: now) { return elsewhere }
            return "It's \(now.formatted(date: .omitted, time: .shortened)), sir."
        }

        let dateAsks = ["what day is it", "whats the date", "what is the date",
                        "whats todays date", "what is todays date", "what's the day",
                        "what day is today"]
        if dateAsks.contains(where: { text.contains($0) }) {
            return "It's \(now.formatted(date: .complete, time: .omitted)), sir."
        }

        if let chance = chanceAnswer(text) { return chance }

        // Arithmetic before the machine questions: "what's 2 plus 2" is not
        // about the Mac, and the sums are the cheapest check of the lot.
        if let sum = Calc.answer(for: transcript) { return sum }
        if let converted = Calc.conversion(for: transcript) { return converted }

        if contains(text, ["how much battery", "hows my battery", "whats my battery",
                           "battery level", "how is the battery", "hows the battery",
                           "how much charge", "am i charging", "is it charging",
                           "how much power"]) {
            return SystemInfo.batteryLine() ?? "This Mac hasn't a battery, sir."
        }

        if contains(text, ["whats my ip", "what is my ip", "my ip address",
                           "whats my address on the network", "am i online",
                           "am i connected"]) {
            return SystemInfo.networkLine()
        }

        if contains(text, ["how long has this been on", "whats my uptime",
                           "what is my uptime", "how long has the mac been up",
                           "how long have you been up", "how long has it been on",
                           "when did i last restart"]) {
            return SystemInfo.uptimeLine()
        }

        if contains(text, ["what can you do", "what can you say", "what are my commands",
                           "what commands do i have", "what do you do",
                           "what else can you do", "list my commands"]) {
            return capabilities(commands)
        }

        if contains(text, ["whats on my clipboard", "what is on my clipboard",
                           "whats in my clipboard", "read my clipboard",
                           "read the clipboard", "whats copied", "what did i copy"]) {
            return Clipboard.spokenSummary()
        }

        // The raw transcript, not the folded one: normalising turns "5:30"
        // into "5 30", and the system date parser wants the colon.
        if let countdown = untilAnswer(transcript, now: now) { return countdown }
        return nil
    }

    /// "say that again", "what was that", "repeat".
    ///
    /// Handled by the caller rather than here, because the thing to repeat is
    /// the *engine's* last answer — this only recognises the request.
    static func isRepeatRequest(_ transcript: String) -> Bool {
        var text = PhraseMatcher.normalize(transcript)
        for name in Resolver.assistantNames
        where text == name || text.hasPrefix(name + " ") {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        for tail in [" please", " for me"] where text.hasSuffix(tail) {
            text = String(text.dropLast(tail.count))
        }
        // Whole sentence, not containment. "What did you say about the weather"
        // is a question about the weather, and repeating the last answer to it
        // would be answering something nobody asked.
        let asks: Set<String> = ["say that again", "say it again", "repeat that",
                                 "repeat it", "repeat", "what was that",
                                 "what did you say", "come again", "say again",
                                 "one more time", "again"]
        return asks.contains(text)
    }

    // MARK: - How long until something

    /// Built once. `NSDataDetector` compiles a good deal of machinery on
    /// creation and has no state to carry between uses.
    private static let dateDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Every opener contains "until", "till" or "til", which is what the tail
    /// is split on. "How long to" is deliberately absent: "how long to boil an
    /// egg" is not a countdown, and there is no safe way to split on "to" —
    /// the word turns up inside "october".
    private static let untilAsks = [
        "how long until", "how long till", "how long til",
        "how many days until", "how many days till", "how many hours until",
        "how many minutes until", "how many weeks until", "how long is it until",
        "time until", "days until", "how many sleeps until",
    ]

    /// Holidays the system date parser has never heard of.
    ///
    /// Small and fixed-date on purpose. Easter moves, and computing it needs
    /// the whole computus; anything that needs a rule rather than a date can go
    /// to the model, which is fine at exactly that.
    private static let fixedHolidays: [String: (month: Int, day: Int)] = [
        "christmas": (12, 25), "christmas day": (12, 25), "xmas": (12, 25),
        "christmas eve": (12, 24), "boxing day": (12, 26),
        "new year": (1, 1), "new years": (1, 1), "new years day": (1, 1),
        "the new year": (1, 1), "new years eve": (12, 31),
        "halloween": (10, 31), "valentines": (2, 14), "valentines day": (2, 14),
        "independence day": (7, 4), "fourth of july": (7, 4), "july fourth": (7, 4),
        "april fools": (4, 1), "april fools day": (4, 1),
        "st patricks day": (3, 17), "saint patricks day": (3, 17),
        "guy fawkes": (11, 5), "bonfire night": (11, 5),
    ]

    /// The next time that month and day comes round, at midnight.
    private static func nextOccurrence(month: Int, day: Int, after now: Date) -> Date? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        var components = DateComponents(year: year, month: month, day: day)
        guard let thisYear = calendar.date(from: components) else { return nil }
        if thisYear > now { return thisYear }
        components.year = year + 1
        return calendar.date(from: components)
    }

    /// "how long until Friday", "how many days until December 25".
    ///
    /// The date comes from the same system parser reminders use, so anything
    /// that works there works here — weekdays, "tomorrow", "next Monday", a
    /// date, a time today. It is gated behind the opener, so an ordinary
    /// question never pays for the detector.
    static func untilAnswer(_ transcript: String, now: Date) -> String? {
        guard contains(PhraseMatcher.normalize(transcript), untilAsks) else { return nil }

        // Everything after the last "until", and this is the whole bug that was
        // here before. Handed the opener as well, `NSDataDetector` swallows the
        // word itself and answers with *today* at four in the afternoon — so
        // "how many days until December 25" came back as an hour and a half.
        // It matched, it returned a date, and the date was nonsense.
        //
        // Split on the raw string rather than the folded one: folding turns
        // "5:30" into "5 30", and the parser wants the colon it threw away.
        guard let tail = tailAfterUntil(transcript) else { return nil }

        guard let target = holiday(in: tail, now: now) ?? parsedDate(in: tail, now: now)
        else { return nil }

        let seconds = target.timeIntervalSince(now)
        guard abs(seconds) < 60 * 60 * 24 * 400 else { return nil }
        if seconds <= 0 {
            return "That was \(SystemInfo.duration(Int(-seconds / 60))) ago, sir."
        }
        // More than a day off is counted in *calendar* days rather than
        // 24-hour blocks, because that is what the question means: on the 4th,
        // Christmas is 112 sleeps away whatever time of day you ask.
        if seconds >= 86400 {
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day],
                                               from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: target)).day ?? 0
            return "\(days) day\(days == 1 ? "" : "s"), sir."
        }
        // Under a minute rounds to zero, and "no time, sir" is not an answer.
        guard seconds >= 60 else { return "Less than a minute, sir." }
        return "\(SystemInfo.duration(Int(seconds / 60))), sir."
    }

    /// What comes after the last "until" / "till" / "til", whole word.
    private static func tailAfterUntil(_ transcript: String) -> String? {
        var best: Range<String.Index>?
        for word in ["until", "till", "til"] {
            var search = transcript.startIndex..<transcript.endIndex
            while let found = transcript.range(of: word, options: [.caseInsensitive], range: search) {
                let beforeOK = found.lowerBound == transcript.startIndex
                    || !transcript[transcript.index(before: found.lowerBound)].isLetter
                let afterOK = found.upperBound == transcript.endIndex
                    || !transcript[found.upperBound].isLetter
                if beforeOK, afterOK, best.map({ found.upperBound > $0.upperBound }) ?? true {
                    best = found
                }
                guard found.upperBound < transcript.endIndex else { break }
                search = found.upperBound..<transcript.endIndex
            }
        }
        guard let best else { return nil }
        let tail = String(transcript[best.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    private static func holiday(in tail: String, now: Date) -> Date? {
        var name = PhraseMatcher.normalize(tail)
        for filler in ["the ", "next "] where name.hasPrefix(filler) {
            name = String(name.dropFirst(filler.count))
        }
        guard let (month, day) = fixedHolidays[name] else { return nil }
        return nextOccurrence(month: month, day: day, after: now)
    }

    private static func parsedDate(in tail: String, now: Date) -> Date? {
        guard let detector = dateDetector else { return nil }
        let range = NSRange(tail.startIndex..., in: tail)
        let dates = detector.matches(in: tail, options: [], range: range).compactMap(\.date)
        // The soonest one still ahead of us, or failing that the last named —
        // "how long until Friday" said on a Friday should say something rather
        // than nothing.
        return dates.filter { $0 > now }.min() ?? dates.last
    }

    /// Answers that are exact but not instant, so they must not run on the main
    /// thread.
    ///
    /// Free disk space is the whole of it, and it earns the separate path:
    /// the figure Finder shows — the one worth saying, because it counts space
    /// macOS would reclaim on demand — costs **ten milliseconds** to read,
    /// measured. That is a dropped frame or two of the HUD's animation for a
    /// number, so the caller runs this on a background queue and delivers the
    /// answer when it arrives.
    static func deferredAnswer(for transcript: String) -> (() -> String?)? {
        let text = PhraseMatcher.normalize(transcript)
        // Deliberately no bare "how much room": that is as likely to be about a
        // suitcase as a disk, and a confident answer to the wrong question is
        // worse than passing it to the model.
        guard contains(text, ["how much space", "how much disk space", "how much storage",
                              "how full is my disk", "how full is the disk",
                              "how much free space", "whats my disk space",
                              "how much space is left", "space left on the disk",
                              "how much room on the disk", "how much room is left"])
        else { return nil }
        return { SystemInfo.diskLine() }
    }

    private static func contains(_ text: String, _ asks: [String]) -> Bool {
        asks.contains { text.contains($0) }
    }

    /// A short, honest list of what this particular Jarvis will do — your own
    /// commands, not a brochure. Held to five because it is spoken aloud.
    static func capabilities(_ commands: [String]) -> String {
        let named = commands.filter { !$0.isEmpty }
        guard !named.isEmpty else {
            return "Open apps and websites, set timers, and answer questions, sir."
        }
        let shown = named.prefix(5)
        var line = "I can do " + Agenda.join(Array(shown))
        if named.count > shown.count { line += ", and \(named.count - shown.count) more" }
        return line + ", sir. Ask me anything else and I'll have a go."
    }

    // MARK: - Coins, dice and numbers

    private static let numberRange = try? NSRegularExpression(
        pattern: #"between (-?[0-9]+) and (-?[0-9]+)"#)
    private static let dieSides = try? NSRegularExpression(pattern: #"\bd([0-9]{1,3})\b"#)

    /// "flip a coin", "roll a die", "pick a number between 1 and 10".
    ///
    /// Worth answering here rather than by the model for a reason beyond speed:
    /// a language model asked for a random number is not random. It has
    /// favourites — sevens and thirty-sevens — and will happily give you the
    /// same one twice in a row.
    ///
    /// Whole words throughout, and it matters more here than anywhere else in
    /// this file. Substring matching read "die" out of *diet*, "coin" out of
    /// *coincidence* and "roll" out of *payroll* and *controller* — so asking
    /// what to eat on a diet was answered with a four. Every other check in
    /// this file matches a multi-word phrase, where a stray substring is
    /// vanishingly unlikely; these are single words, where it is inevitable.
    static func chanceAnswer(_ text: String) -> String? {
        let haystack = PhraseMatcher.Haystack(text)
        func said(_ phrase: String) -> Bool {
            PhraseMatcher.containsTokenRun(haystack, phrase)
        }

        if said("coin") || said("heads or tails") || said("tails or heads") {
            return Bool.random() ? "Heads, sir." : "Tails, sir."
        }

        if let match = numberRange?.firstMatch(
            in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let lowRange = Range(match.range(at: 1), in: text),
           let highRange = Range(match.range(at: 2), in: text),
           let low = Int(text[lowRange]), let high = Int(text[highRange]) {
            let bounds = low <= high ? (low, high) : (high, low)
            return "\(Int.random(in: bounds.0...bounds.1)), sir."
        }

        guard said("dice") || said("die") || said("roll") || said("dies")
        else { return nil }

        // "roll a d20" — the sides are named. Anything above a thousand is a
        // misheard sentence rather than a die.
        var sides = 6
        if let match = dieSides?.firstMatch(
            in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let named = Int(text[range]), (2...1000).contains(named) {
            sides = named
        }
        let count = said("two dice") || said("2 dice") ? 2 : 1
        let rolls = (0..<count).map { _ in Int.random(in: 1...sides) }
        guard count > 1 else { return "\(rolls[0]), sir." }
        return "\(rolls.map(String.init).joined(separator: " and ")) — \(rolls.reduce(0, +)), sir."
    }

    // MARK: - The time somewhere else

    /// Zone *identifiers* keyed by the city in them, built once.
    ///
    /// No table to maintain: macOS already ships six hundred zone identifiers
    /// shaped `Region/City`, so the city is simply the last path component with
    /// its underscores turned back into spaces. "New York", "Los Angeles" and
    /// "Tokyo" all fall out of that for free.
    ///
    /// Deliberately strings rather than `TimeZone`s. Constructing all six
    /// hundred zones took **ten milliseconds** — measured — on the main thread,
    /// the first time anyone asked the time anywhere. Keeping the identifier
    /// and building the single zone that matched costs a fifth of a
    /// millisecond, and the other five hundred and ninety-nine are never built.
    private static let cityZoneIdentifiers: [String: String] = {
        var table: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            let key = PhraseMatcher.normalize(city.replacingOccurrences(of: "_", with: " "))
            guard !key.isEmpty, table[key] == nil else { continue }
            table[key] = identifier
        }
        return table
    }()

    /// Builds the city table off the main thread, before anything needs it.
    ///
    /// Reading the zone list and folding it costs a few milliseconds, which is
    /// a dropped frame of the HUD if it happens the moment you ask the time
    /// somewhere. Same bargain the voice catalogue makes: pay it in the
    /// background, during the seconds you are speaking.
    static func warm() {
        DispatchQueue.global(qos: .utility).async { _ = cityZoneIdentifiers.count }
    }

    /// "what time is it in tokyo" — nil when no city is named, which is the
    /// common case and costs one `range(of:)`.
    static func worldClock(_ text: String, now: Date) -> String? {
        guard let marker = text.range(of: " in ", options: .backwards) else { return nil }
        let city = String(text[marker.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty, city.count <= 30,
              let identifier = cityZoneIdentifiers[city],
              let zone = TimeZone(identifier: identifier)
        else { return nil }

        var formatter = Date.FormatStyle(date: .omitted, time: .shortened)
        formatter.timeZone = zone
        let name = city.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return "It's \(now.formatted(formatter)) in \(name), sir."
    }

    static func looksLikeQuestion(_ transcript: String) -> Bool {
        var text = PhraseMatcher.normalize(transcript)
        guard !text.isEmpty else { return false }

        for name in Resolver.assistantNames
        where text == name || text.hasPrefix(name + " ") {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Just the name, nothing after it: you're addressing him, not ordering
        // anything. Worth a "Yes, sir?" rather than silence.
        if text.isEmpty { return true }

        // Whole-sentence, so this runs before the two-word floor below.
        if greetings.contains(text) { return true }

        let words = text.split(separator: " ").map(String.init)
        // One word is never enough to act on — it's still being spoken.
        guard words.count >= 2 else { return false }

        for phrase in phrases where text.hasPrefix(phrase) { return true }
        // "flip a coin" and "roll a die" are orders, not questions, but they
        // want an answer all the same and there is nowhere else for them to go.
        for phrase in imperatives where text.hasPrefix(phrase) { return true }
        guard let first = words.first else { return false }
        return starters.contains(first)
    }
}
