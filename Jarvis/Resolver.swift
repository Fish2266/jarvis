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
    /// You asked for it to come to you ("bring over xcode") rather than to be
    /// taken to it, so its windows move to the desktop you're on.
    var bringHere: Bool = false
    /// You asked for it to stop ("quit chrome") rather than to start.
    var quitTarget: Bool = false
    /// "open a new tab" / "open a new window" — a fresh tab or window in the
    /// browser rather than just bringing it forward. Only set for a command
    /// that opens the browser itself; a website command uses `forceNewTab`.
    var browserFresh: Browser.Fresh? = nil
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

    /// Verbs that mean "come to me" rather than "take me there".
    ///
    /// "bring up" is deliberately absent: it lives in `verbs` and still means
    /// open. The two lists are searched together for the *longest* match, so
    /// "bring up chrome" keeps its old behaviour — eight characters of
    /// "bring up" beat the five of the bare "bring" that would fetch it here.
    static let bringVerbs = [
        "bring over", "bring here", "bring me", "move over", "move here",
        "send over", "send here", "pull over", "drag over", "bring", "gimme",
    ]

    /// Verbs that end an app rather than start one.
    ///
    /// Deliberately short, and deliberately without "shut down" or "power
    /// off": those belong to the sentence about the *Mac*, and the one thing
    /// worse than a command that doesn't work is one that works on the wrong
    /// noun. "quit chrome" ends Chrome; nothing here can end anything else.
    ///
    /// `terminate` is the polite request an app gets from ⌘Q, so unsaved work
    /// still gets its "do you want to save?" — this asks an app to stop, it
    /// does not kill it.
    static let quitVerbs = [
        "force quit", "quit out of", "quit", "close down", "close", "kill",
    ]

    /// Direction words that can trail the target instead of leading it, as in
    /// "bring xcode over here". None of them are part of an app's name.
    static let bringTail: Set<String> = ["over", "here", "to", "me", "my", "way", "now"]

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

    /// Drops a leading "jarvis" and nothing else — what you actually said, minus
    /// the name you said it to.
    static func withoutAssistantName(_ normalized: String) -> String {
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
        return text
    }

    /// Strips a leading "jarvis" and a leading verb, returning what's left,
    /// whether the verb was one that asks the app to come here, and whether it
    /// was one that asks the app to stop.
    static func strip(_ normalized: String)
        -> (target: String, sawVerb: Bool, bringHere: Bool, quitHere: Bool) {
        let text = withoutAssistantName(normalized)

        // Longest match across all three lists rather than first-listed, so a
        // verb that is a prefix of another can't shadow it from any direction.
        var matched = ""
        var bring = false
        var quit = false
        for verb in verbs
        where verb.count > matched.count && (text == verb || text.hasPrefix(verb + " ")) {
            matched = verb
            (bring, quit) = (false, false)
        }
        for verb in bringVerbs
        where verb.count > matched.count && (text == verb || text.hasPrefix(verb + " ")) {
            matched = verb
            (bring, quit) = (true, false)
        }
        for verb in quitVerbs
        where verb.count > matched.count && (text == verb || text.hasPrefix(verb + " ")) {
            matched = verb
            (bring, quit) = (false, true)
        }
        guard !matched.isEmpty else { return (text, false, false, false) }

        var rest = String(text.dropFirst(matched.count)).trimmingCharacters(in: .whitespaces)
        if bring || quit { rest = dropBringTail(rest) }
        return (rest, true, bring, quit)
    }

    /// "bring xcode over here" -> "xcode". Never strips the last word standing,
    /// so "bring me here" doesn't dissolve into nothing.
    static func dropBringTail(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last, bringTail.contains(last) {
            words.removeLast()
        }
        if words.count == 1, bringTail.contains(words[0]) { return "" }
        return words.joined(separator: " ")
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

    /// Reads "tab" or "window" out of what was said.
    ///
    /// Taken from the words rather than from which phrase happened to match, so
    /// it holds up whatever the command is named. "window" wins over "tab"
    /// wherever both appear, because that word is the only thing separating
    /// "open a new window" from "open a new tab".
    static func freshBrowser(in text: String) -> Browser.Fresh? {
        var found: Browser.Fresh?
        for word in text.split(separator: " ") {
            if word == "window" || word == "windows" { return .window }
            if found == nil, word == "tab" || word == "tabs" { found = .tab }
        }
        return found
    }

    /// Your commands, with every phrase normalized and split once.
    ///
    /// The transcript side of the comparison has been prepared this way since
    /// `Haystack`; the phrase side never was, so a hundred-odd phrases were
    /// being re-normalized and re-split on *every partial transcript* — a few
    /// dozen times per spoken sentence. Measured at 100 µs a call, which was
    /// more than half of what resolving a command cost.
    ///
    /// Held by the listener and rebuilt only when the commands change, which is
    /// when the answer could actually differ.
    struct Catalog {
        struct Command {
            let macro: Macro
            /// Normalized, split, and empty phrases already dropped.
            let phrases: [PhraseMatcher.Needle]
        }

        let macros: [Macro]
        /// Only the commands the fuzzy loop can reach. The capture and
        /// exact-phrase kinds are matched by other means entirely, so
        /// preparing their phrases would be work for nobody.
        let fuzzy: [Command]

        init(_ macros: [Macro]) {
            self.macros = macros
            fuzzy = macros
                .filter { $0.enabled && !$0.kind.capturesText && !$0.kind.requiresExactPhrase }
                .map { macro in
                    Command(macro: macro, phrases: macro.phrases
                        .map { PhraseMatcher.Needle(PhraseMatcher.normalize($0)) }
                        .filter { !$0.isEmpty })
                }
        }
    }

    /// Convenience for callers with no catalog to hand — the editor's "Try it
    /// now", the tests. Identical in every respect but the preparation, which
    /// it pays for inline exactly as this used to on every call.
    static func resolveFast(transcript: String, macros: [Macro]) -> Resolution? {
        resolveFast(transcript: transcript, catalog: Catalog(macros))
    }

    static func resolveFast(transcript: String, catalog: Catalog) -> Resolution? {
        let macros = catalog.macros
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
        let spoken = withoutAssistantName(whole)
        let (rawTarget, sawVerb, bringHere, quitHere) = strip(whole)
        let (target, forceNewTab) = stripNewQualifier(rawTarget, macros: macros)

        // Exact-phrase commands get their own pass. They must not be reachable
        // by containment — "how do i sleep better" contains "sleep" — and
        // equally not through a verb: "open sleep" asks to open something
        // called Sleep, and "bring over sleep" asks to fetch a window. Neither
        // is a request to sleep the Mac.
        //
        // Matching the sentence with only the assistant's name taken off is
        // what draws that line. Comparing the verb-stripped target instead let
        // any verb at all through, because "open sleep" reduces to "sleep";
        // "jarvis go to sleep" still lands here, because dropping the name
        // leaves the phrase itself.
        for macro in macros where macro.enabled && macro.kind.requiresExactPhrase {
            for phrase in macro.phrases {
                let p = PhraseMatcher.normalize(phrase)
                guard !p.isEmpty else { continue }
                let tolerance = p.count >= 7 ? 1 : 0
                if PhraseMatcher.editDistance(spoken, p) <= tolerance {
                    return Resolution(macro: macro, confidence: 1.0, source: .macro)
                }
            }
        }

        var best: Resolution?

        // Split once, then scored against every phrase of every command. Both
        // forms are needed: a phrase can be a whole catchphrase ("wake up
        // daddys home") or just the target that follows a verb ("the craft").
        let wholeHay = PhraseMatcher.Haystack(whole)
        let targetHay = target.isEmpty ? nil : PhraseMatcher.Haystack(target)

        for command in catalog.fuzzy {
            var score = 0.0
            for p in command.phrases {
                // Nothing under the threshold, or under the best already found,
                // can win — and a phrase told what it has to beat stops
                // measuring as soon as it can't get there.
                let bar = max(macroThreshold, best?.confidence ?? 0, score)
                score = max(score, PhraseMatcher.scoreNormalized(wholeHay, p, atLeast: bar))
                if let targetHay {
                    score = max(score, PhraseMatcher.scoreNormalized(
                        targetHay, p, atLeast: max(bar, score)))
                }
            }
            if score >= macroThreshold, score > (best?.confidence ?? 0) {
                best = Resolution(macro: command.macro, confidence: score, source: .macro,
                                  chromeProfile: spokenProfile, forceNewTab: forceNewTab,
                                  bringHere: bringHere, quitTarget: quitHere)
            }
        }
        if var best {
            // Only an app command opens the browser itself. A website command
            // means a tab of that site, which `forceNewTab` already covers.
            if best.macro.kind == .app { best.browserFresh = freshBrowser(in: whole) }
            return best
        }

        // Nothing user-defined matched. If they clearly asked to open something,
        // fall back to the installed-app list so every app works for free.
        guard sawVerb, target.count >= 3,
              let (entry, score) = AppIndex.shared.best(matching: target, threshold: appThreshold)
        else { return nil }

        let macro = Macro(name: entry.name, phrases: [entry.normalized],
                          kind: .app, target: entry.path)
        return Resolution(macro: macro, confidence: score, source: .appIndex,
                          chromeProfile: spokenProfile, forceNewTab: forceNewTab,
                          bringHere: bringHere, quitTarget: quitHere)
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
        let named = PhraseMatcher.Haystack(n)
        for macro in macros where macro.enabled && !macro.kind.requiresExactPhrase {
            let bar = max(macroThreshold, best?.confidence ?? 0)
            let macroName = PhraseMatcher.normalize(macro.name)
            var score = PhraseMatcher.scoreNormalized(
                PhraseMatcher.Haystack(macroName), n, atLeast: bar)
            score = max(score, PhraseMatcher.scoreNormalized(
                named, macroName, atLeast: max(bar, score)))
            for phrase in macro.phrases {
                score = max(score, PhraseMatcher.scoreNormalized(
                    PhraseMatcher.Haystack(PhraseMatcher.normalize(phrase)), n,
                    atLeast: max(bar, score)))
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
