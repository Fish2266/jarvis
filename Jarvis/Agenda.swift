import EventKit
import Foundation

/// Reading back what's on today — reminders you've set and events in your
/// calendar.
///
/// The mirror image of `Reminders`, which only ever writes. Everything here is
/// read-only: there is no code path from a spoken phrase to deleting a
/// reminder or moving a meeting, which is deliberate. Voice recognition is
/// good, not perfect, and the cost of a misheard "delete" is not symmetrical
/// with the cost of a misheard "read".
enum Agenda {

    /// Its own store rather than `Reminders`'s. Calendar access and reminder
    /// access are separate grants, and a store asked for one does not carry
    /// the other — sharing it would mean a calendar prompt appearing the first
    /// time you added a reminder.
    private static let store = EKEventStore()

    /// Drops whatever the store has cached, so a read sees the database as it
    /// is now.
    ///
    /// Two reasons, and both are real. A reminder ticked off in another app
    /// since the last read would otherwise still be read out — this is the
    /// call EventKit provides for exactly that. And a store that existed
    /// *before* access was granted holds the state it had then; every path
    /// here goes through this first, so it cannot matter which grant arrived
    /// in which order.
    private static func refresh() { store.reset() }

    enum AgendaError: LocalizedError {
        case remindersDenied
        case calendarDenied

        var errorDescription: String? {
            switch self {
            case .remindersDenied:
                return "Reminders access is off — turn it on in Privacy & Security"
            case .calendarDenied:
                return "Calendar access is off — turn it on in Privacy & Security"
            }
        }
    }

    // MARK: - Access

    static var remindersAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static var calendarAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    private static func ensureReminders(_ next: @escaping (Bool) -> Void) {
        if remindersAuthorized { next(true); return }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .denied || status == .restricted { next(false); return }
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async { next(granted) }
        }
    }

    private static func ensureCalendar(_ next: @escaping (Bool) -> Void) {
        if calendarAuthorized { next(true); return }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted { next(false); return }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { next(granted) }
        }
    }

    // MARK: - Reminders

    /// Everything still open and due today or overdue, soonest first.
    ///
    /// Reminders with no due date are included: a list you never dated is
    /// still a list of things to do, and leaving them out made "what are my
    /// reminders" answer "nothing, sir" to a screen full of them.
    static func reminders(completion: @escaping (Result<String, Error>) -> Void) {
        func done(_ result: Result<String, Error>) {
            DispatchQueue.main.async { completion(result) }
        }
        ensureReminders { granted in
            guard granted else { done(.failure(AgendaError.remindersDenied)); return }
            refresh()

            // Deliberately an unbounded predicate, filtered afterwards.
            //
            // Asking EventKit for reminders "due before tonight" excludes the
            // ones with no due date at all — and a list you never dated is
            // still a list of things to do. Answering "nothing outstanding,
            // sir" to a screen full of undated reminders is the wrong answer
            // to the question that was asked, so the range is applied here
            // instead, where undated can mean "always relevant".
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: nil)
            let cutoff = endOfToday()
            store.fetchReminders(matching: predicate) { found in
                // EventKit answers on a private queue, so everything below is
                // off the main thread already — which is where the sorting and
                // string building want to be anyway.
                let items = (found ?? []).filter { reminder in
                    guard !reminder.isCompleted else { return false }
                    guard let due = reminder.dueDateComponents?.date else { return true }
                    return due < cutoff
                }
                guard !items.isEmpty else {
                    done(.success("Nothing outstanding, sir."))
                    return
                }
                let sorted = items.sorted { left, right in
                    switch (left.dueDateComponents?.date, right.dueDateComponents?.date) {
                    case let (l?, r?): return l < r
                    case (nil, _?):    return false      // undated goes last
                    case (_?, nil):    return true
                    default:           return left.title ?? "" < right.title ?? ""
                    }
                }
                done(.success(summarize(sorted.compactMap(\.title), noun: "reminder")))
            }
        }
    }

    // MARK: - Calendar

    /// Today's remaining events, and the next one specifically.
    static func today(completion: @escaping (Result<String, Error>) -> Void) {
        events(upcomingOnly: true) { result in
            completion(result.map { events in
                guard !events.isEmpty else { return "Your calendar is clear, sir." }
                return summarize(events.map(describe), noun: "thing")
            })
        }
    }

    static func next(completion: @escaping (Result<String, Error>) -> Void) {
        events(upcomingOnly: true) { result in
            completion(result.map { events in
                guard let soonest = events.first else { return "Nothing else today, sir." }
                return "Next up: \(describe(soonest))."
            })
        }
    }

    private static func events(upcomingOnly: Bool,
                               completion: @escaping (Result<[EKEvent], Error>) -> Void) {
        func done(_ result: Result<[EKEvent], Error>) {
            DispatchQueue.main.async { completion(result) }
        }
        ensureCalendar { granted in
            guard granted else { done(.failure(AgendaError.calendarDenied)); return }
            refresh()

            // Off the main thread: `events(matching:)` reads the calendar
            // database synchronously, and this runs while the HUD is animating.
            DispatchQueue.global(qos: .userInitiated).async {
                let now = Date()
                let predicate = store.predicateForEvents(
                    withStart: now, end: endOfToday(), calendars: nil)
                var found = store.events(matching: predicate)
                if upcomingOnly {
                    // An all-day event has no useful start time to compare
                    // against, and is worth mentioning all day.
                    found = found.filter { $0.isAllDay || $0.endDate > now }
                }
                done(.success(found.sorted { $0.startDate < $1.startDate }))
            }
        }
    }

    private static func describe(_ event: EKEvent) -> String {
        let title = event.title?.trimmingCharacters(in: .whitespaces) ?? "an untitled event"
        guard !event.isAllDay else { return "\(title), all day" }
        return "\(title) at \(event.startDate.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Shared

    /// The end of today in the user's own calendar, which is not the same as
    /// "now plus twenty-four hours" — asked at nine in the evening, that would
    /// pull in most of tomorrow.
    private static func endOfToday() -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? Date().addingTimeInterval(86400)
    }

    /// A list, said out loud rather than printed.
    ///
    /// Held to three because this is spoken: a fourteen-item list read aloud is
    /// not information, it's noise, and by item five you have stopped
    /// listening. The count comes first so the number is the thing you hear
    /// even if you tune out the rest.
    static func summarize(_ items: [String], noun: String, limit: Int = 3) -> String {
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "Nothing, sir." }

        let shown = Array(cleaned.prefix(limit))
        let list = join(shown)
        if cleaned.count == 1 { return "One \(noun), sir: \(list)." }
        var line = "\(cleaned.count) \(noun)s, sir: \(list)"
        if cleaned.count > shown.count {
            let rest = cleaned.count - shown.count
            line += ", and \(rest) more"
        }
        return line + "."
    }

    /// "a, b and c" — the spoken form, with no serial comma to read out.
    static func join(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
