import Foundation

struct Resolution {
    enum Source: String { case macro, appIndex, model }
    let macro: Macro
    let confidence: Double
    let source: Source
    /// Set when you named a profile out loud ("open chrome on work"). Overrides
    /// whatever profile the command itself is pinned to.
    var chromeProfile: String? = nil
    /// Free text captured after a trigger phrase, for commands like reminders.
    var payload: String? = nil
    /// You explicitly asked for a new one ("open a new gmail tab"), so don't
    /// reuse a tab that's already open.
    var forceNewTab: Bool = false
}

/// Tier 1: pure string work, no model, effectively instant.
///
/// Everything the app does normally resolves here. The language model is only
/// consulted when this comes back empty.
enum Resolver {

    /// Longest first, so "start up" wins over "start".
    static let verbs = [
        "would you kindly open", "could you open", "can you open",
        "fire up", "boot up", "start up", "spin up", "pull up", "bring up",
        "open up", "take me to", "show me", "go to", "get me",
        "launch", "open", "start", "boot", "run", "load", "play",
    ]

    static let assistantNames = ["hey jarvis", "ok jarvis", "okay jarvis", "jarvis"]

    static let macroThreshold = 0.72
    static let appThreshold = 0.80

    /// Words that can introduce a spoken profile: "chrome **on** work".
    static let profileConnectors: Set<String> = ["on", "in", "with", "using", "under", "for"]
    /// Filler that can sit between the connector and the profile name.
    static let profileFiller: Set<String> = ["my", "the", "a", "one", "profile", "account", "side"]

    /// Splits a trailing profile qualifier off the request.
    ///
    /// "open chrome on work" -> ("open chrome", "Default")
    /// Leaves the text untouched unless the trailing words genuinely name a
    /// profile, so ordinary phrases containing "on" or "with" are unaffected.
    static func stripProfileQualifier(_ text: String, profiles: [ChromeProfile])
        -> (rest: String, profile: String?) {
        guard !profiles.isEmpty else { return (text, nil) }
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 3 else { return (text, nil) }

        // Scan from the end so the last connector wins.
        for index in stride(from: tokens.count - 2, through: 1, by: -1) {
            guard profileConnectors.contains(tokens[index]) else { continue }
            let tail = tokens[(index + 1)...].filter { !profileFiller.contains($0) }
            guard !tail.isEmpty,
                  let match = Browser.matchProfile(tail.joined(separator: " "), in: profiles)
            else { continue }
            let rest = tokens[0..<index].joined(separator: " ")
            guard !rest.isEmpty else { continue }
            return (rest, match.directory)
        }
        return (text, nil)
    }

    /// Strips a leading "jarvis" and a leading verb, returning what's left.
    static func strip(_ normalized: String) -> (target: String, sawVerb: Bool) {
        var text = normalized

        for name in assistantNames where text == name || text.hasPrefix(name + " ") {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        // Speech recognition mishears the name often enough ("travis", "jarvez")
        // that a near miss on the first word still counts, as long as a command
        // follows it.
        var words = text.split(separator: " ").map(String.init)
        if words.count > 1, words[0] != "jarvis", words[0].count >= 5,
           PhraseMatcher.editDistance(words[0], "jarvis") <= 2 {
            words.removeFirst()
            text = words.joined(separator: " ")
        }

        for verb in verbs where text == verb || text.hasPrefix(verb + " ") {
            let rest = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            return (rest, true)
        }
        return (text, false)
    }

    /// For commands whose phrase is a prefix ("remind me to …"), matches the
    /// prefix and hands back everything after it, taken from the original text
    /// so capitalisation survives.
    /// Words that can't be a reminder on their own — a payload made only of
    /// these means the sentence isn't finished yet.
    static let fillerOnly: Set<String> = [
        "in", "to", "at", "on", "the", "a", "an", "of", "for", "by", "and",
        "me", "my", "that", "this", "it", "is", "about", "with", "up",
    ]

    static func capturePayload(normalized: String, original: String,
                               phrases: [String]) -> String? {
        var tokens = normalized.split(separator: " ").map(String.init)
        var consumed = 0

        for name in assistantNames where normalized == name || normalized.hasPrefix(name + " ") {
            let count = name.split(separator: " ").count
            tokens = Array(tokens.dropFirst(count))
            consumed += count
            break
        }

        // Longest phrase first, so "remind me to" beats "remind me" and the
        // payload doesn't start with a stray "to".
        for phrase in phrases.sorted(by: { $0.split(separator: " ").count > $1.split(separator: " ").count }) {
            let normalizedPhrase = PhraseMatcher.normalize(phrase)
            guard !normalizedPhrase.isEmpty else { continue }
            let phraseTokens = normalizedPhrase.split(separator: " ").map(String.init)
            let count = phraseTokens.count
            guard tokens.count > count else { continue }
            // Token by token, so "remind me to" can't swallow the "to" of "tomorrow".
            let matched = zip(tokens.prefix(count), phraseTokens)
                .allSatisfy { PhraseMatcher.tokenMatches($0, $1) }
            guard matched else { continue }

            let originalWords = original.split(separator: " ").map(String.init)
            let payload = originalWords.dropFirst(consumed + count).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-"))
            guard !payload.isEmpty else { return nil }

            // "remind me in" is a half-finished sentence, not a reminder called "in".
            let words = PhraseMatcher.normalize(payload).split(separator: " ").map(String.init)
            guard words.contains(where: { !fillerOnly.contains($0) }) else { return nil }
            return payload
        }
        return nil
    }

    private static let newWords: Set<String> = ["new", "a", "an", "another"]
    private static let tabWords: Set<String> = ["tab", "window", "one"]

    /// "a new gmail tab" -> ("gmail", forceNew: true).
    ///
    /// Left alone when the whole thing is itself a command phrase, so "new tab"
    /// still means the Chrome command rather than a new anything-else.
    static func stripNewQualifier(_ target: String, macros: [Macro]) -> (target: String, forceNew: Bool) {
        var words = target.split(separator: " ").map(String.init)
        guard let first = words.first, newWords.contains(first) else { return (target, false) }

        for macro in macros where macro.enabled {
            for phrase in macro.phrases where PhraseMatcher.normalize(phrase) == target {
                return (target, false)
            }
        }
        // A bare "a" isn't a request for a new one; "new" or "another" is.
        guard words.contains("new") || words.contains("another") else { return (target, false) }

        while let first = words.first, newWords.contains(first) { words.removeFirst() }
        while let last = words.last, tabWords.contains(last) { words.removeLast() }
        let rest = words.joined(separator: " ")
        return rest.isEmpty ? (target, false) : (rest, true)
    }

    static func resolveFast(transcript: String, macros: [Macro]) -> Resolution? {
        let raw = PhraseMatcher.normalize(transcript)
        guard !raw.isEmpty else { return nil }

        // Capture commands run against the raw text: a reminder's content may
        // itself contain words like "with" or "on" that profile-stripping eats.
        for macro in macros where macro.enabled && macro.kind.capturesText {
            if let payload = capturePayload(normalized: raw, original: transcript,
                                            phrases: macro.phrases) {
                return Resolution(macro: macro, confidence: 0.95, source: .macro, payload: payload)
            }
        }

        let (whole, spokenProfile) = stripProfileQualifier(raw, profiles: Browser.chromeProfiles())
        let (rawTarget, sawVerb) = strip(whole)
        let (target, forceNewTab) = stripNewQualifier(rawTarget, macros: macros)

        // Exact-phrase commands get their own pass. They must not be reachable
        // by containment: "how do i sleep better" contains "sleep".
        for macro in macros where macro.enabled && macro.kind.requiresExactPhrase {
            for phrase in macro.phrases {
                let p = PhraseMatcher.normalize(phrase)
                guard !p.isEmpty else { continue }
                let tolerance = p.count >= 7 ? 1 : 0
                if PhraseMatcher.editDistance(target, p) <= tolerance
                    || PhraseMatcher.editDistance(whole, p) <= tolerance {
                    return Resolution(macro: macro, confidence: 1.0, source: .macro)
                }
            }
        }

        var best: Resolution?

        for macro in macros
        where macro.enabled && !macro.kind.capturesText && !macro.kind.requiresExactPhrase {
            var score = 0.0
            for phrase in macro.phrases {
                let p = PhraseMatcher.normalize(phrase)
                guard !p.isEmpty else { continue }
                // A phrase can be a whole catchphrase ("wake up daddys home")
                // or just the target that follows a verb ("the craft").
                score = max(score, PhraseMatcher.scoreNormalized(whole, p))
                if !target.isEmpty {
                    score = max(score, PhraseMatcher.scoreNormalized(target, p))
                }
            }
            if score >= macroThreshold, score > (best?.confidence ?? 0) {
                best = Resolution(macro: macro, confidence: score, source: .macro,
                                  chromeProfile: spokenProfile, forceNewTab: forceNewTab)
            }
        }
        if let best { return best }

        // Nothing user-defined matched. If they clearly asked to open something,
        // fall back to the installed-app list so every app works for free.
        guard sawVerb, target.count >= 3,
              let (entry, score) = AppIndex.shared.best(matching: target, threshold: appThreshold)
        else { return nil }

        let macro = Macro(name: entry.name, phrases: [entry.normalized],
                          kind: .app, target: entry.path)
        return Resolution(macro: macro, confidence: score, source: .appIndex,
                          chromeProfile: spokenProfile, forceNewTab: forceNewTab)
    }

    /// Candidate list handed to the model when Tier 1 finds nothing.
    static func candidates(macros: [Macro]) -> [Macro] {
        // Exact-phrase commands are left out on purpose: the language model
        // should never be able to decide to put the Mac to sleep.
        macros.filter { $0.enabled && !$0.kind.requiresExactPhrase }
    }

    /// Resolve a bare name — what tier 2 hands back — against your commands and
    /// then every installed app.
    ///
    /// Routing the model's answer back through the same matching the rest of the
    /// app uses means it can reach any installed app, and can't fire something
    /// unrelated to what it named: if the name matches nothing, nothing happens.
    static func resolveNamed(_ name: String, macros: [Macro]) -> Resolution? {
        let n = PhraseMatcher.normalize(name)
        guard !n.isEmpty, n != "none", n.count >= 2 else { return nil }

        var best: Resolution?
        for macro in macros where macro.enabled && !macro.kind.requiresExactPhrase {
            var score = PhraseMatcher.scoreNormalized(PhraseMatcher.normalize(macro.name), n)
            score = max(score, PhraseMatcher.scoreNormalized(n, PhraseMatcher.normalize(macro.name)))
            for phrase in macro.phrases {
                score = max(score, PhraseMatcher.scoreNormalized(PhraseMatcher.normalize(phrase), n))
            }
            if score >= macroThreshold, score > (best?.confidence ?? 0) {
                best = Resolution(macro: macro, confidence: score, source: .model)
            }
        }
        if let best { return best }

        guard n.count >= 3,
              let (entry, score) = AppIndex.shared.best(matching: n, threshold: appThreshold)
        else { return nil }
        return Resolution(
            macro: Macro(name: entry.name, phrases: [entry.normalized], kind: .app, target: entry.path),
            confidence: score, source: .model)
    }
}
