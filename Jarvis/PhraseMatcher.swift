import Foundation

/// Fuzzy matcher for the wake phrase. Speech recognition rarely returns the
/// exact string ("wake up daddy's home" comes back as "wake up daddies home",
/// "wake up daddy home", etc.), so we accept anything close enough.
enum PhraseMatcher {

    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        // Spaces are held back rather than written, which collapses runs and
        // trims both ends in the same pass the characters are copied in.
        var pendingSpace = false

        func emit(_ ch: Character) {
            if ch.isLetter || ch.isNumber {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                return                        // don't let apostrophes split words
            } else if !out.isEmpty {
                pendingSpace = true
            }
        }

        // Nothing in ASCII carries a diacritic, so the fold is a no-op there —
        // and skipping it matters: this runs against every phrase of every
        // command on every partial transcript, and the fold was most of its cost.
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            for byte in s.utf8 {
                let lowered = (byte >= 65 && byte <= 90) ? byte + 32 : byte
                emit(Character(UnicodeScalar(lowered)))
            }
            return out
        }

        let folded = s.lowercased().folding(options: [.diacriticInsensitive],
                                            locale: Locale(identifier: "en_US"))
        for ch in folded { emit(ch) }
        return out
    }

    static func matches(transcript: String, phrase: String, threshold: Double = 0.78) -> Bool {
        score(transcript: transcript, phrase: phrase) >= threshold
    }

    /// 0…1 confidence that `transcript` contains `phrase`. Already-normalized
    /// inputs can go through `scoreNormalized` to skip the folding work.
    static func score(transcript: String, phrase: String) -> Double {
        scoreNormalized(normalize(transcript), normalize(phrase))
    }

    /// Like `scoreNormalized` but WITHOUT the containment shortcut, so "new"
    /// doesn't score 0.97 against "News" just for being a prefix of it.
    static func similarityNormalized(_ n: String, _ p: String) -> Double {
        guard !n.isEmpty, !p.isEmpty else { return 0 }
        if n == p { return 1.0 }
        return max(bestWindowSimilarity(haystack: n, needle: p),
                   tokenCoverage(haystack: n, needle: p) * 0.92)
    }

    /// True when `needle`'s words appear as a run of whole words in `haystack`
    /// — "chrome" in "google chrome", but not "new" in "news".
    static func containsTokenRun(_ haystack: String, _ needle: String) -> Bool {
        let hay = haystack.split(separator: " ").map(String.init)
        let need = needle.split(separator: " ").map(String.init)
        guard !need.isEmpty, need.count <= hay.count else { return false }
        for start in 0...(hay.count - need.count) {
            if zip(need, hay[start...]).allSatisfy({ $0 == $1 }) { return true }
        }
        return false
    }

    static func scoreNormalized(_ n: String, _ p: String) -> Double {
        guard !n.isEmpty, !p.isEmpty else { return 0 }
        if n == p { return 1.0 }
        // Whole-phrase containment is as good as an exact hit for our purposes.
        if n.contains(p) { return 0.97 }

        let window = bestWindowSimilarity(haystack: n, needle: p)
        // Coverage is the looser signal, so it can't score as high on its own.
        let coverage = tokenCoverage(haystack: n, needle: p) * 0.92
        return max(window, coverage)
    }

    /// Slide a word-aligned window roughly the length of the phrase across the
    /// transcript and keep the best edit-distance similarity.
    private static func bestWindowSimilarity(haystack: String, needle: String) -> Double {
        // Characters rather than Strings: the window is rebuilt on every step of
        // an O(words squared) walk, and as a String that meant a fresh Array()
        // conversion and an O(n) .count each time round.
        let words = haystack.split(separator: " ").map(Array.init)
        let target = Array(needle)
        guard !words.isEmpty else { return 0 }

        let floor = target.count / 2
        let ceiling = Int(Double(target.count) * 1.4)
        var window: [Character] = []
        window.reserveCapacity(haystack.count)

        var best = 0.0
        for start in words.indices {
            window.removeAll(keepingCapacity: true)
            for end in start..<words.count {
                if !window.isEmpty { window.append(" ") }
                window.append(contentsOf: words[end])
                if window.count < floor { continue }
                best = max(best, similarity(window, target))
                if window.count > ceiling { break }
            }
        }
        return best
    }

    /// Fraction of the phrase's words that show up in the transcript, allowing
    /// one typo per word for words of four letters or more.
    private static func tokenCoverage(haystack: String, needle: String) -> Double {
        // Split to characters once, not once per (needle token, haystack token)
        // pair as the Array() calls inside the loop used to.
        let hay = haystack.split(separator: " ").map(Array.init)
        let need = needle.split(separator: " ").map(Array.init)
        guard !need.isEmpty else { return 0 }

        var hits = 0
        for token in need {
            let budget = token.count >= 4 ? 1 : 0
            // An edit distance is never smaller than the difference in length,
            // so a token the budget can't cover on length alone skips the matrix.
            if hay.contains(where: { abs($0.count - token.count) <= budget
                                     && levenshtein($0, token) <= budget }) {
                hits += 1
            }
        }
        return Double(hits) / Double(need.count)
    }

    /// Whole-token match: identical, or one typo on words of four letters or more.
    ///
    /// Deliberately NOT substring-based. "remind me to" is a substring of
    /// "remind me tomorrow", which is exactly the kind of accidental match that
    /// must not happen when a phrase decides where the spoken content begins.
    static func tokenMatches(_ spoken: String, _ expected: String) -> Bool {
        if spoken == expected { return true }
        guard expected.count >= 4, abs(spoken.count - expected.count) <= 1
        else { return false }
        return levenshtein(Array(spoken), Array(expected)) <= 1
    }

    private static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1.0 - Double(levenshtein(a, b)) / Double(longest)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        levenshtein(Array(a), Array(b))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
