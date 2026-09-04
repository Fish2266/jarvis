import Foundation
import IOKit.pwr_mgt

/// Stops the Mac dozing off, for a while or until told otherwise.
///
/// The exact opposite of the sleep command, and the reason both exist: telling
/// a Mac to sleep is easy, and stopping it is the thing you actually want half
/// way through a long download.
///
/// This is `caffeinate` without the process — the same power-management
/// assertion, taken in process. The assertion is released when the time is up,
/// when you say so, and when the app quits; an assertion that outlived its
/// owner would leave the Mac awake with nothing left to explain why.
final class KeepAwake {

    static let shared = KeepAwake()
    private init() {}

    private var assertion: IOPMAssertionID = 0
    private var work: DispatchWorkItem?
    private(set) var until: Date?

    /// Fired on the main queue whenever it starts, ends, or is replaced.
    var onChange: ((Date?, Bool) -> Void)?

    var isActive: Bool { assertion != 0 }

    /// How long is left, or nil when it is holding indefinitely.
    var remaining: TimeInterval? {
        guard let until else { return nil }
        return max(0, until.timeIntervalSinceNow)
    }

    /// Takes the assertion. `duration` of nil holds it until told to stop.
    ///
    /// Deliberately `PreventUserIdleSystemSleep` rather than the display
    /// assertion: this is for a Mac that must keep *working*, and forcing the
    /// screen to stay lit as well would burn a laptop's battery down for a
    /// download that needed neither.
    @discardableResult
    func start(for duration: TimeInterval?) -> Bool {
        // Replace rather than stack. Two assertions would need two releases,
        // and the second "stay awake" would silently leak the first.
        release()

        var id: IOPMAssertionID = 0
        let reason = "Jarvis was asked to keep this Mac awake" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        guard result == kIOReturnSuccess else { return false }
        assertion = id

        if let duration, duration > 0 {
            until = Date().addingTimeInterval(duration)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isActive else { return }
                self.stop()
            }
            self.work = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        } else {
            until = nil
        }
        onChange?(until, true)
        return true
    }

    @discardableResult
    func stop() -> Bool {
        guard isActive else { return false }
        release()
        onChange?(nil, false)
        return true
    }

    private func release() {
        work?.cancel()
        work = nil
        until = nil
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    // MARK: - Reading the request

    enum Intent: Equatable {
        case hold(TimeInterval?)     // nil: until told otherwise
        case release
        case report
    }

    private static let releaseWords = [
        "let it sleep", "you can sleep", "stop", "cancel", "off", "never mind",
        "nevermind", "release", "allow sleep", "let it rest", "done",
    ]
    private static let reportWords = [
        "how long", "how much longer", "still", "whats left", "status", "am i",
    ]

    /// "stay awake for two hours", "let it sleep", "how much longer".
    ///
    /// Same ordering rule as the timer, for the same reason: a release that
    /// happens to name a duration must not be read as a fresh hold.
    static func intent(in sentence: String) -> Intent {
        let normalized = PhraseMatcher.normalize(sentence)
        let haystack = PhraseMatcher.Haystack(normalized)
        func said(_ phrase: String) -> Bool {
            PhraseMatcher.containsTokenRun(haystack, phrase)
        }

        if releaseWords.contains(where: said) { return .release }
        // The timer already knows how to read "for two hours" out of a
        // sentence, and having two of those to keep in step would be one too
        // many.
        if let duration = Countdown.duration(in: normalized) { return .hold(duration) }
        if reportWords.contains(where: said) { return .report }
        return .hold(nil)
    }

    /// "two hours" / "until you say otherwise", for the spoken line.
    static func describe(_ until: Date?) -> String {
        guard let until else { return "until you say otherwise" }
        return "for another \(Countdown.spoken(max(0, until.timeIntervalSinceNow)))"
    }
}
