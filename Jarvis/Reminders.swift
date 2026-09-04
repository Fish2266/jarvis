import EventKit
import Foundation

/// Adds items to Apple Reminders.
///
/// The spoken text is split into a title and an optional due date using
/// NSDataDetector — the same date parser the rest of the system uses — so
/// "call mom tomorrow at 5" becomes a reminder titled "call mom" due then.
enum Reminders {

    private static let store = EKEventStore()

    enum RemindersError: LocalizedError {
        case denied
        case emptyTitle
        case noList

        var errorDescription: String? {
            switch self {
            case .denied:     return "Reminders access is off — turn it on in Privacy & Security"
            case .emptyTitle: return "I didn't catch what to remind you about"
            case .noList:     return "No Reminders list available"
            }
        }
    }

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .denied || status == .restricted
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    private static func ensureAccess(_ next: @escaping (Bool) -> Void) {
        if isAuthorized { next(true); return }
        if isDenied { next(false); return }
        requestAccess(next)
    }

    /// Pulls a date out of the text and returns the rest as the title.
    ///
    /// The date can sit anywhere: "brush my teeth on September 3rd at 10am" and
    /// "September 3rd at 10am to brush my teeth" both give the same result. The
    /// longest date match wins, and connector words left dangling at either end
    /// ("to", "at", "on") are trimmed off.
    /// Built once. `NSDataDetector` compiles a good deal of machinery on
    /// creation, and it has no state to carry between uses.
    private static let dateDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)

    static func parse(_ text: String) -> (title: String, due: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector = dateDetector
        else { return (trimmed, nil) }

        // NSDataDetector handles "September 3rd at 10am" and "tomorrow at 5pm",
        // but not durations like "in 30 minutes" — those are parsed separately.
        if let relative = relativeDate(in: trimmed) {
            var title = trimmed
            title.removeSubrange(relative.range)
            title = tidy(title)
            return title.isEmpty ? (trimmed, relative.date) : (title, relative.date)
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = detector.matches(in: trimmed, options: [], range: range)
        // Prefer the longest match so "September 3rd at 10am" beats "September 3rd".
        guard let match = matches.max(by: { $0.range.length < $1.range.length }),
              let date = match.date, let matched = Range(match.range, in: trimmed)
        else { return (trimmed, nil) }

        var title = trimmed
        title.removeSubrange(matched)
        title = tidy(title)

        // If stripping the date left nothing useful, keep the whole phrase.
        return title.isEmpty ? (trimmed, date) : (title, date)
    }

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty five": 45, "fortyfive": 45, "sixty": 60, "ninety": 90,
        "half": 0.5, "couple": 2, "few": 3,
        "a couple": 2, "a couple of": 2, "couple of": 2, "a few": 3,
    ]

    private static let unitSeconds: [String: Double] = [
        "second": 1, "sec": 1, "minute": 60, "min": 60,
        "hour": 3600, "hr": 3600, "day": 86400, "week": 604800,
    ]

    /// Matches durations like "in 30 minutes", "in an hour", "in half an hour".
    private static func relativeDate(in text: String) -> (date: Date, range: Range<String.Index>)? {
        let pattern = #"\bin\s+(a couple of|a couple|couple of|a few|[0-9]+|couple|few|half|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|sixty|ninety)\s+(?:of\s+)?(?:an?\s+)?(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }

        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: full),
              let whole = Range(match.range, in: text),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text)
        else { return nil }

        let amountText = text[amountRange].lowercased()
        let amount = Double(amountText) ?? numberWords[amountText]
        guard let amount else { return nil }

        // Trim the plural, then look the unit up.
        var unit = text[unitRange].lowercased()
        if unit.hasSuffix("s") { unit.removeLast() }
        guard let seconds = unitSeconds[unit] else { return nil }

        return (Date().addingTimeInterval(amount * seconds), whole)
    }

    /// Words that only ever glued the date to the sentence.
    private static let connectors = ["at", "on", "by", "in", "for", "this", "next",
                                     "the", "a", "of", "to", "that", "me", "and"]

    /// Removes connector words the date phrase left dangling at either end.
    private static func tidy(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
            let lower = result.lowercased()
            for word in connectors {
                if lower.hasSuffix(" \(word)") {
                    result = String(result.dropLast(word.count + 1)); changed = true; break
                }
                // Only strip a leading connector when real words follow it.
                if lower.hasPrefix("\(word) "), result.split(separator: " ").count > 1 {
                    result = String(result.dropFirst(word.count + 1)); changed = true; break
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func list(named name: String?) -> EKCalendar? {
        let lists = store.calendars(for: .reminder)
        guard let name, !name.isEmpty else {
            return store.defaultCalendarForNewReminders() ?? lists.first
        }
        let wanted = PhraseMatcher.normalize(name)
        let match = lists.first { PhraseMatcher.normalize($0.title) == wanted }
            ?? lists.first { PhraseMatcher.scoreNormalized(
                PhraseMatcher.normalize($0.title), wanted) >= 0.8 }
        return match ?? store.defaultCalendarForNewReminders() ?? lists.first
    }

    /// Creates the reminder and returns a short line describing what was added.
    static func add(_ text: String, listName: String? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        ensureAccess { granted in
            guard granted else { completion(.failure(RemindersError.denied)); return }

            // Reading the calendar list and committing the save both touch the
            // EventKit store, which goes to disk. That ran on the main thread,
            // in the middle of the HUD's confirmation animation; the reminder
            // is already decided by this point, so none of it needs to be there.
            DispatchQueue.global(qos: .userInitiated).async {
                let (title, due) = parse(text)
                func done(_ result: Result<String, Error>) {
                    DispatchQueue.main.async { completion(result) }
                }
                guard !title.isEmpty else { done(.failure(RemindersError.emptyTitle)); return }
                guard let calendar = list(named: listName) else {
                    done(.failure(RemindersError.noList)); return
                }

                let reminder = EKReminder(eventStore: store)
                reminder.title = title
                reminder.calendar = calendar
                if let due {
                    reminder.dueDateComponents = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: due)
                    reminder.addAlarm(EKAlarm(absoluteDate: due))
                }

                do {
                    try store.save(reminder, commit: true)
                    var summary = title
                    if let due { summary += " · \(due.formatted(date: .abbreviated, time: .shortened))" }
                    done(.success(summary))
                } catch {
                    done(.failure(error))
                }
            }
        }
    }
}
