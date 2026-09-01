import Foundation
import FoundationModels
import os

@Generable
private struct Target {
    @Guide(description: "Name of the command or Mac app the user wants, or NONE")
    let name: String
}

@Generable
private struct Line {
    @Guide(description: "One spoken sentence, at most 11 words, in JARVIS's voice. No quotation marks.")
    let line: String
}

/// Wrapper around Apple's on-device model.
///
/// Two jobs, both optional — the app works with this entirely switched off:
///   1. Interpreting a command the deterministic resolver couldn't place.
///   2. Writing the spoken reply, after the action has already happened.
///
/// Neither ever blocks opening an app.
final class Intelligence {

    static let shared = Intelligence()
    private init() {}

    /// Kept alive only to hold the model in memory; requests use fresh sessions
    /// so no transcript history accumulates between commands.
    private var warmSession: LanguageModelSession?
    private var lastPrewarm = Date.distantPast

    /// Session setup blocks for over a second the first time, so it never runs
    /// on the main thread — that delay used to hold up the HUD.
    private let queue = DispatchQueue(label: "jarvis.intelligence", qos: .userInitiated)

    private var cachedAvailability: (value: Bool, reason: String?, checkedAt: Date)?
    /// `isAvailable` is read from main (the menu), from the prewarm queue, and
    /// from whatever executor the async requests land on, so the cache behind it
    /// needs a lock — it holds a String, and a torn read there is a crash.
    private var availabilityLock = os_unfair_lock()

    var isAvailable: Bool { availability().value }
    var unavailableReason: String? { availability().reason }

    /// Cached briefly — the menu asks on every open, and this shouldn't be a
    /// framework round trip each time.
    private func availability() -> (value: Bool, reason: String?) {
        os_unfair_lock_lock(&availabilityLock)
        let cached = cachedAvailability
        os_unfair_lock_unlock(&availabilityLock)
        if let cached, Date().timeIntervalSince(cached.checkedAt) < 60 {
            return (cached.value, cached.reason)
        }
        let result: (Bool, String?)
        switch SystemLanguageModel.default.availability {
        case .available:
            result = (true, nil)
        case .unavailable(let why):
            switch why {
            case .deviceNotEligible:
                result = (false, "This Mac doesn't support Apple Intelligence")
            case .appleIntelligenceNotEnabled:
                result = (false, "Apple Intelligence is switched off in System Settings")
            case .modelNotReady:
                result = (false, "Apple Intelligence is still downloading its model")
            @unknown default:
                result = (false, "Apple Intelligence is unavailable")
            }
        }
        os_unfair_lock_lock(&availabilityLock)
        cachedAvailability = (result.0, result.1, Date())
        os_unfair_lock_unlock(&availabilityLock)
        return result
    }

    /// Called on the double clap. Cold start costs seconds; warm calls cost
    /// ~300 ms, so we spend the listening window loading the model.
    func prewarm() {
        guard Date().timeIntervalSince(lastPrewarm) > 20 else { return }
        lastPrewarm = Date()
        queue.async { [weak self] in
            guard let self, self.isAvailable else { return }
            if self.warmSession == nil {
                self.warmSession = LanguageModelSession(instructions: Self.resolverInstructions)
            }
            self.warmSession?.prewarm()
        }
    }

    // MARK: - Tier 2: interpreting a command

    private static let resolverInstructions = """
    You work out what the user wants opened or done, and name it.

    Reply with the name of one of their listed commands, or the name of a Mac app \
    they are asking for. The user speaks casually and will rarely use the exact \
    name — infer what they mean. "check my inbox" is the mail command; "put a \
    record on" is a music app.

    Reply with exactly NONE if the speech is idle conversation, a false trigger, \
    or you cannot tell what they want.
    """

    /// Names what the user wants. The caller resolves that name through the same
    /// deterministic matcher tier 1 uses, so the model can reach any installed app
    /// but can never fire something unrelated to the name it gave.
    func resolveTarget(transcript: String, commands: [String],
                       timeout: TimeInterval = 4.0) async -> String? {
        guard isAvailable else { return nil }

        let list = commands.isEmpty ? "(none defined)" : commands.joined(separator: ", ")
        let prompt = "Their commands: \(list)\n\nSpoken: \"\(transcript)\""

        let result = await Self.withTimeout(timeout) { () -> String in
            let session = LanguageModelSession(instructions: Self.resolverInstructions)
            let response = try await session.respond(
                to: prompt, generating: Target.self,
                options: GenerationOptions(temperature: 0.0, maximumResponseTokens: 16))
            return response.content.name
        }

        guard let name = result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.uppercased() != "NONE"
        else { return nil }
        return name
    }

    // MARK: - Tier 3: the spoken reply

    private static let jarvisInstructions = """
    You are JARVIS, Tony Stark's AI butler from Iron Man, confirming an action you \
    have just completed.

    Voice: crisp British formality, bone-dry wit, quietly amused. Understated, never eager. \
    Address the user as "sir" — never "my master", "my dear", "my lord", or by name.

    You are given ACTION and possibly HEARD. Confirm the ACTION. HEARD is only the phrase \
    the user happened to say to trigger it — never reply to its literal meaning, never \
    repeat it back. If HEARD is a silly catchphrase, you may be faintly amused by it, but \
    the ACTION is what you are acknowledging.

    Rules:
    - ONE sentence, 11 words maximum.
    - Never ask a question. Never offer further help. Never introduce yourself.
    - Do not reuse the example lines below; write a fresh one every time.
    - No emoji, no quotation marks, no stage directions.

    Examples:
    ACTION: Opened Spotify. HEARD: "put some tunes on"
    -> Spotify is up, sir.
    ACTION: Opened the calculator. HEARD: "jarvis do some math"
    -> Calculator ready, sir. Try not to strain yourself.
    """

    static let cannedReplies = [
        "Welcome home, sir.", "Right away, sir.", "As you wish, sir.",
        "Done, sir.", "Of course, sir.", "At once, sir.",
    ]

    /// Never throws and never blocks anything — falls back to a canned line.
    func reply(action: String, heard: String, timeout: TimeInterval = 3.0) async -> String {
        let fallback = Self.cannedReplies.randomElement() ?? "Right away, sir."
        guard isAvailable else { return fallback }

        var prompt = "ACTION: \(action)."
        if !heard.isEmpty { prompt += " HEARD: \"\(heard)\"" }

        let result = await Self.withTimeout(timeout) { () -> String in
            let session = LanguageModelSession(instructions: Self.jarvisInstructions)
            let response = try await session.respond(
                to: prompt, generating: Line.self,
                options: GenerationOptions(temperature: 1.1, maximumResponseTokens: 32))
            return response.content.line
        }

        return Self.sanitize(result) ?? fallback
    }

    /// The model occasionally ignores the length guide or wraps things in quotes.
    /// Anything that doesn't look like a short spoken line gets rejected.
    static func sanitize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }

        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }

        // JARVIS confirms; he doesn't ask. The model often appends a helpful
        // "Anything else?" — drop just that sentence rather than the whole line,
        // which would throw away a perfectly good reply.
        text = dropQuestions(from: text)

        let words = text.split(separator: " ").count
        guard words >= 1, words <= 16, text.count <= 120 else { return nil }
        return text
    }

    private static func dropQuestions(from text: String) -> String {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        let kept = sentences.filter { !$0.hasSuffix("?") }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Answering a question

    static let answerInstructions = """
    You are JARVIS, Tony Stark's AI butler from Iron Man, replying out loud to \
    whatever the user has just said to you.

    Voice: crisp British formality, bone-dry wit, quietly amused. Address the \
    user as "sir".

    Rules:
    - Answer the question, or return the greeting, in the first sentence.
    - Greetings and small talk get a short, warm reply, not an explanation.
    - Asked for help, an idea, a name or a choice, commit to one concrete \
    suggestion at once. Never offer to think about it, never promise it for \
    later, never ask which sort they had in mind — assume something sensible.
    - At most two sentences and 35 words. This is spoken aloud.
    - No lists, no markdown, no emoji, no stage directions.
    - Say you don't know only when it's a matter of fact you genuinely lack.
      A request for an idea always has an answer.
    """

    /// Openers that ask for something to be produced rather than looked up.
    ///
    /// This model reliably fumbles exactly this shape: asked to "help me think
    /// of an idea", it offers to think of one, asks which sort you had in mind,
    /// or answers about its own dog. Naming the deliverable in the prompt is
    /// what gets a real answer out of it — the rule in the instructions above
    /// is not enough on its own.
    static let requestOpeners = [
        "help me", "i need help", "i need an idea", "i need a", "come up with",
        "think of", "give me an idea", "give me some", "any ideas", "suggest",
        "recommend", "pick a", "pick me", "choose a", "decide", "what should i",
    ]

    static func framing(for question: String) -> String {
        let text = PhraseMatcher.normalize(question)
        guard requestOpeners.contains(where: { text.contains($0) }) else { return "" }
        return """


        They are asking you for the thing, not asking whether you can get it. \
        Reply with the thing itself — the actual idea, name or choice, picked \
        and stated outright, and it is theirs, not yours. One sentence, \
        twenty-five words at the outside. No offer to help, no follow-up question.
        """
    }

    /// Answers a spoken question. Returns nil if the model is off or too slow,
    /// so the caller can say something honest instead of hanging.
    func answer(_ question: String, timeout: TimeInterval = 8.0) async -> String? {
        guard isAvailable else { return nil }

        // The model has no clock or calendar of its own.
        let now = Date().formatted(date: .complete, time: .shortened)
        let prompt = "For reference, right now it is \(now).\n\nThe user said: "
            + question + Self.framing(for: question)

        let result = await Self.withTimeout(timeout) { () -> String in
            let session = LanguageModelSession(instructions: Self.answerInstructions)
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 70))
            return response.content
        }
        return Self.sanitizeAnswer(result)
    }

    /// Answers may be two sentences, so this is looser than the one-line reply
    /// guard — but it still strips markdown and refuses a wall of text.
    static func sanitizeAnswer(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }

        text = text.replacingOccurrences(of: "\n", with: " ")
        // Bold markers go first, keeping their text: **Paris** is an answer.
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        // Now whole *smirks* spans, which are stage directions, not content.
        for pattern in ["\\*[^*]{1,40}\\*", "_[^_]{1,40}_"] {
            text = text.replacingOccurrences(of: pattern, with: "",
                                             options: .regularExpression)
        }
        for marker in ["`", "#", "*", "- "] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.trimmingCharacters(in: .whitespaces)

        // Spoken aloud, so hold it to a couple of sentences however chatty the
        // model felt. The instructions ask for this; they aren't always obeyed.
        //
        // Trim rather than reject. A perfectly good idea that ran to three
        // sentences used to be thrown away whole, and you'd hear "I haven't an
        // answer for that" instead of the answer it had already produced.
        let cleaned = text
        text = firstSentences(of: cleaned, limit: 2)
        if !fitsAloud(text) { text = firstSentences(of: cleaned, limit: 1) }

        guard fitsAloud(text), !text.isEmpty else { return nil }
        return text
    }

    /// Short enough to say out loud without becoming a monologue.
    static func fitsAloud(_ text: String) -> Bool {
        let words = text.split(separator: " ").count
        return words >= 1 && words <= 45 && text.count <= 300
    }

    static func firstSentences(of text: String, limit: Int) -> String {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        guard sentences.count > limit else { return text }

        var kept = sentences.prefix(limit).joined(separator: " ")
        // A first sentence of two words isn't an answer; take one more.
        if kept.split(separator: " ").count < 5, sentences.count > limit {
            kept = sentences.prefix(limit + 1).joined(separator: " ")
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Timeout

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping () async throws -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
