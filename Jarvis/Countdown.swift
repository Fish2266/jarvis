import Foundation

/// A kitchen timer.
///
/// One at a time, deliberately. A list of named timers would need a way to say
/// which one you meant, a way to show several at once, and a way to cancel the
/// right one — three new things to get wrong for a feature whose whole appeal
/// is that you say six words and forget about it. Starting a second timer
/// replaces the first and Jarvis says so, which is the honest version of a
/// limit rather than a silent one.
///
/// Nothing here polls. The deadline is a single timer scheduled once; the
/// display asks how long is left when it wants to draw, and gets an answer
/// from arithmetic on two dates rather than from a counter something had to
/// keep up to date.
final class Countdown {

    static let shared = Countdown()
    private init() {}

    struct Running {
        let duration: TimeInterval
        let startedAt: Date
        let firesAt: Date

        var remaining: TimeInterval { max(0, firesAt.timeIntervalSinceNow) }
        /// 0 at the start, 1 when it fires.
        var progress: Double {
            guard duration > 0 else { return 1 }
            return min(1, max(0, 1 - remaining / duration))
        }
    }

    private(set) var running: Running?
    private var work: DispatchWorkItem?

    /// Fired on the main queue when the time is up.
    var onFire: (() -> Void)?
    /// Fired on the main queue whenever the timer starts, is replaced, or is
    /// cancelled — so the display can appear and disappear without polling.
    var onChange: ((Running?) -> Void)?

    var isRunning: Bool { running != nil }

    /// Starts a timer, replacing any already running. Returns whether one was
    /// replaced, so the spoken line can mention it.
    @discardableResult
    func start(_ duration: TimeInterval) -> Bool {
        let replaced = running != nil
        work?.cancel()

        let now = Date()
        let state = Running(duration: duration, startedAt: now,
                            firesAt: now.addingTimeInterval(duration))
        running = state

        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.running,
                  current.firesAt == state.firesAt else { return }
            self.running = nil
            self.work = nil
            // Deliberately no `onChange(nil)` here. That is the "put the
            // display away" signal, and a timer going off wants the opposite —
            // the display stays to announce it, then leaves on its own.
            self.onFire?()
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        onChange?(state)
        return replaced
    }

    @discardableResult
    func cancel() -> Bool {
        guard running != nil else { return false }
        work?.cancel()
        work = nil
        running = nil
        onChange?(nil)
        return true
    }

    // MARK: - Reading the request

    enum Intent: Equatable {
        case set(TimeInterval)
        case cancel
        case report
        /// A timer was clearly asked for, but with no length attached.
        case needsDuration
    }

    private static let cancelWords = [
        "cancel", "stop", "clear", "forget", "kill", "abort", "never mind", "nevermind",
    ]
    private static let reportWords = [
        "how long", "how much", "how many", "whats left", "what is left",
        "time left", "left on", "remaining", "check the timer", "status",
    ]

    /// Works out what a sentence about timers is asking for.
    ///
    /// Cancelling is checked before the length, and that order is the whole
    /// point: "cancel the five minute timer" names a duration, and looking for
    /// one first turned a request to stop a timer into a request to start
    /// another. The two mistakes are not symmetrical — a cancel misread as a
    /// set leaves a timer running that you believe you stopped.
    static func intent(in sentence: String) -> Intent {
        let normalized = PhraseMatcher.normalize(sentence)
        let haystack = PhraseMatcher.Haystack(normalized)
        func said(_ phrase: String) -> Bool {
            PhraseMatcher.containsTokenRun(haystack, phrase)
        }

        if cancelWords.contains(where: said) { return .cancel }
        if let duration = duration(in: normalized), duration > 0 { return .set(duration) }
        if reportWords.contains(where: said) { return .report }
        return .needsDuration
    }

    /// Number words a recogniser actually returns spelled out.
    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "twenty": 20, "thirty": 30, "forty": 40, "forty five": 45, "fifty": 50,
        "sixty": 60, "ninety": 90, "half": 0.5, "couple": 2, "few": 3,
    ]

    private static let unitSeconds: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600,
    ]

    /// Total seconds named anywhere in the sentence.
    ///
    /// Amounts add up, so "an hour and a half" and "one hour thirty minutes"
    /// both come to ninety minutes. An amount with no unit after it is skipped
    /// rather than guessed at — "timer for 5" could mean seconds or minutes,
    /// and picking one silently is how a five-second timer becomes a
    /// five-minute one.
    static func duration(in normalized: String) -> TimeInterval? {
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        var total: Double = 0
        var found = false
        var index = 0
        var pendingAmount: Double?
        /// The unit the last amount was spent on, so a fraction trailing at the
        /// end can be charged to it: "an hour and a half".
        var lastUnit: Double?
        /// Whether an "and" is still open. "two and a half hours" is two *plus*
        /// a half; without this the half simply replaced the two and a
        /// two-and-a-half-hour timer ran for thirty minutes.
        var sawAnd = false

        /// A fraction after an "and" adds to what is already there; anything
        /// else starts a new amount.
        func combine(_ value: Double) -> Double {
            guard sawAnd, let current = pendingAmount, value < 1 else { return value }
            return current + value
        }

        while index < words.count {
            let word = words[index]

            if let seconds = unitSeconds[word] {
                total += (pendingAmount ?? 1) * seconds
                pendingAmount = nil
                lastUnit = seconds
                found = true
                sawAnd = false
                index += 1
                continue
            }
            // "and" and "of" are the only words allowed to sit inside an
            // amount without ending it, so both leave `sawAnd` as they found it.
            if word == "and" { sawAnd = true; index += 1; continue }
            if word == "of" { index += 1; continue }
            // The article between an amount and its unit is filler, not a
            // number. Reading the "an" of "half an hour" as one overwrote the
            // half and turned a thirty-minute timer into an hour.
            if word == "a" || word == "an" {
                if pendingAmount == nil, !sawAnd { pendingAmount = 1 }
                index += 1
                continue
            }
            if let digits = Double(word) {
                pendingAmount = combine(digits)
                sawAnd = false
                index += 1
                continue
            }
            if let spelled = numberWords[word] {
                // "twenty five minutes": a round ten followed by a unit digit.
                if spelled >= 20, spelled.truncatingRemainder(dividingBy: 10) == 0,
                   index + 1 < words.count, let units = numberWords[words[index + 1]],
                   units < 10, units >= 1 {
                    pendingAmount = spelled + units
                    sawAnd = false
                    index += 2
                    continue
                }
                pendingAmount = combine(spelled)
                sawAnd = false
                index += 1
                continue
            }
            pendingAmount = nil
            sawAnd = false
            index += 1
        }
        // "an hour and a half" leaves a half with no unit of its own. A
        // fraction is unambiguous — it can only mean a fraction of the unit
        // just used — so it is charged there. A whole number left dangling is
        // not: "an hour and 30" could be minutes or seconds, and is dropped.
        if let spare = pendingAmount, spare > 0, spare < 1, let unit = lastUnit {
            total += spare * unit
        }
        guard found, total > 0 else { return nil }
        // A day-long kitchen timer is a misheard sentence, not a request.
        return total <= 24 * 3600 ? total : nil
    }

    // MARK: - Saying it

    /// "4:32" for the display — minutes and seconds, hours when there are any.
    static func clock(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "five minutes", "an hour and a half" — for speaking, not for a display.
    static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else {
            return "\(total) second\(total == 1 ? "" : "s")"
        }
        let minutes = total / 60
        let rest = total % 60
        var line = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        if minutes >= 60 {
            let hours = minutes / 60
            let spare = minutes % 60
            line = "\(hours) hour\(hours == 1 ? "" : "s")"
            if spare > 0 { line += " and \(spare) minute\(spare == 1 ? "" : "s")" }
            return line
        }
        if rest > 0 { line += " and \(rest) second\(rest == 1 ? "" : "s")" }
        return line
    }
}
