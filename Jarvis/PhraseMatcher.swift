import Foundation

/// Fuzzy matcher for the wake phrase. Speech recognition rarely returns the
/// exact string ("wake up daddy's home" comes back as "wake up daddies home",
/// "wake up daddy home", etc.), so we accept anything close enough.
enum PhraseMatcher {

    static func normalize(_ s: String) -> String {
        // Spaces are held back rather than written, which collapses runs and
        // trims both ends in the same pass the characters are copied in.

        // Nothing in ASCII carries a diacritic, so the fold is a no-op there,
        // and letter-or-number is exactly [a-z0-9] once the byte is lowered.
        // Worth the separate path: this runs against every phrase of every
        // command on every partial transcript, and going byte-wise skips both
        // the fold and the grapheme-cluster work of building Characters.
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(s.utf8.count)
            var pendingSpace = false
            for byte in s.utf8 {
                let c = (byte >= 65 && byte <= 90) ? byte + 32 : byte
                if (c >= 97 && c <= 122) || (c >= 48 && c <= 57) {
                    if pendingSpace { bytes.append(32); pendingSpace = false }
                    bytes.append(c)
                } else if c == 0x27 {
                    continue              // don't let apostrophes split words
                } else if !bytes.isEmpty {
                    pendingSpace = true
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        let folded = s.lowercased().folding(options: [.diacriticInsensitive],
                                            locale: Locale(identifier: "en_US"))
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue
            } else if !out.isEmpty {
                pendingSpace = true
            }
        }
        return out
    }

    /// Which characters a string contains, as one bit each.
    ///
    /// The point of it: an edit distance is at least the number of *distinct*
    /// characters the target needs and the source hasn't got, because each one
    /// has to be inserted or substituted in, and no single edit can supply two
    /// of them. So a phrase whose letters are largely absent from a window can
    /// be rejected by counting bits instead of filling in a matrix.
    ///
    /// Twenty-six letters and ten digits, which is everything `normalize`
    /// produces from ASCII. Anything else — a folded character the non-ASCII
    /// path let through — shares the last bit. That makes the filter weaker
    /// for those strings and never wrong: a shared bit can only make two
    /// characters look alike, which loses a skip rather than causing one.
    static func mask<S: Sequence<Character>>(of characters: S) -> UInt64 {
        var bits: UInt64 = 0
        for c in characters {
            guard let ascii = c.asciiValue else { bits |= 1 << 63; continue }
            if ascii >= 97, ascii <= 122 { bits |= 1 << UInt64(ascii - 97) }
            else if ascii >= 48, ascii <= 57 { bits |= 1 << UInt64(ascii - 48 + 26) }
            else if ascii != 32 { bits |= 1 << 63 }
        }
        return bits
    }

    static func matches(transcript: String, phrase: String, threshold: Double = 0.78) -> Bool {
        score(transcript: transcript, phrase: phrase) >= threshold
    }

    /// 0…1 confidence that `transcript` contains `phrase`. Already-normalized
    /// inputs can go through `scoreNormalized` to skip the folding work.
    static func score(transcript: String, phrase: String) -> Double {
        scoreNormalized(normalize(transcript), normalize(phrase))
    }

    // MARK: - The text being matched against

    /// A normalized transcript, split once.
    ///
    /// `Resolver.resolveFast` scores the same sentence against every phrase of
    /// every command and then against every installed app — a hundred and forty
    /// times over on this Mac. Splitting it into words, and each word into
    /// characters, was being redone for each of them, twice: once by the window
    /// walk and once by the coverage count.
    ///
    /// The characters are held as one flat array with a range per word, so a
    /// window of consecutive words is a *slice* of it. That is what the window
    /// walk actually wants, and it means the walk no longer builds anything:
    /// it used to allocate and copy a fresh array for every window of every
    /// phrase, which was the largest single cost in the resolver.
    struct Haystack {
        let text: String
        /// The words rejoined by a single space. Identical to `text` for
        /// normalized input, which is what every caller passes; built this way
        /// so the ranges below are exact whatever arrives.
        fileprivate let packed: [Character]
        fileprivate let wordRanges: [Range<Int>]
        /// One per word, so a window's mask is the OR of the words in it and
        /// costs nothing to extend as the window grows.
        fileprivate let wordMasks: [UInt64]

        var characters: Int { packed.count }
        var wordCount: Int { wordRanges.count }
        /// Read once. Every phrase compares its own length against this before
        /// searching, so it is asked a hundred-odd times per transcript.
        let utf8Count: Int

        init(_ normalized: String) {
            text = normalized
            utf8Count = normalized.utf8.count
            var characters: [Character] = []
            characters.reserveCapacity(normalized.count)
            var ranges: [Range<Int>] = []
            var masks: [UInt64] = []
            for word in normalized.split(separator: " ") {
                if !characters.isEmpty { characters.append(" ") }
                let start = characters.count
                characters.append(contentsOf: word)
                ranges.append(start..<characters.count)
                masks.append(PhraseMatcher.mask(of: word))
            }
            packed = characters
            wordRanges = ranges
            wordMasks = masks
        }

        /// The words from `start` through `end`, inclusive, with the single
        /// spaces between them — a slice, not a copy.
        fileprivate func window(_ start: Int, _ end: Int) -> ArraySlice<Character> {
            packed[wordRanges[start].lowerBound..<wordRanges[end].upperBound]
        }

        fileprivate func word(_ index: Int) -> ArraySlice<Character> {
            packed[wordRanges[index]]
        }

        fileprivate func wordMask(_ index: Int) -> UInt64 { wordMasks[index] }
    }

    /// A normalized phrase, split once — the mirror of `Haystack`.
    ///
    /// `Haystack` fixed this for the transcript and left the other side of the
    /// comparison alone. Every phrase was still being turned into an array of
    /// characters *and* an array of arrays of characters on every partial
    /// transcript: with a hundred-odd phrases that came to 100 µs a call, more
    /// than half the cost of resolving anything, and all of it re-deriving
    /// something that only changes when you edit your commands.
    ///
    /// Built once by `Resolver.Catalog` and reused for the life of the command
    /// list. The `String` overloads below still build one per call, which is
    /// what the old signature did anyway, so nothing that used them got slower.
    struct Needle {
        let text: String
        let utf8Count: Int
        fileprivate let characters: [Character]
        fileprivate let words: [[Character]]
        fileprivate let mask: UInt64
        fileprivate let wordMasks: [UInt64]

        var isEmpty: Bool { text.isEmpty }

        init(_ normalized: String) {
            text = normalized
            utf8Count = normalized.utf8.count
            characters = Array(normalized)
            let split = normalized.split(separator: " ").map(Array.init) as [[Character]]
            words = split
            mask = PhraseMatcher.mask(of: normalized)
            wordMasks = split.map { PhraseMatcher.mask(of: $0) }
        }
    }

    /// Like `scoreNormalized` but WITHOUT the containment shortcut, so "new"
    /// doesn't score 0.97 against "News" just for being a prefix of it.
    static func similarityNormalized(_ n: String, _ p: String) -> Double {
        similarity(Haystack(n), p, atLeast: 0)
    }

    /// The same, against a transcript that has already been split.
    ///
    /// `bar` is the score the caller would need to care about the answer: the
    /// match threshold, or the best it has already found. Anything below that is
    /// reported as some value below it rather than computed exactly, which is
    /// what lets the edit distance give up early. Pass 0 for an exact answer.
    static func similarity(_ h: Haystack, _ p: String, atLeast bar: Double) -> Double {
        similarity(h, Needle(p), atLeast: bar)
    }

    static func similarity(_ h: Haystack, _ p: Needle, atLeast bar: Double) -> Double {
        guard !h.text.isEmpty, !p.isEmpty else { return 0 }
        if h.text == p.text { return 1.0 }
        return max(bestWindowSimilarity(h, needle: p, atLeast: bar),
                   tokenCoverage(h, needle: p, atLeast: bar / 0.92) * 0.92)
    }

    /// True when `needle`'s words appear as a run of whole words in `haystack`
    /// — "chrome" in "google chrome", but not "new" in "news".
    static func containsTokenRun(_ haystack: String, _ needle: String) -> Bool {
        containsTokenRun(Haystack(haystack), needle)
    }

    static func containsTokenRun(_ h: Haystack, _ needle: String) -> Bool {
        containsTokenRun(h, Needle(needle))
    }

    static func containsTokenRun(_ h: Haystack, _ needle: Needle) -> Bool {
        let need = needle.words
        guard !need.isEmpty, need.count <= h.wordCount else { return false }
        for start in 0...(h.wordCount - need.count) {
            var matched = true
            for offset in need.indices where !h.word(start + offset).elementsEqual(need[offset]) {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    static func scoreNormalized(_ n: String, _ p: String) -> Double {
        scoreNormalized(Haystack(n), p, atLeast: 0)
    }

    static func scoreNormalized(_ h: Haystack, _ p: String, atLeast bar: Double) -> Double {
        scoreNormalized(h, Needle(p), atLeast: bar)
    }

    static func scoreNormalized(_ h: Haystack, _ p: Needle, atLeast bar: Double) -> Double {
        guard !h.text.isEmpty, !p.isEmpty else { return 0 }
        if h.text == p.text { return 1.0 }
        // Whole-phrase containment is as good as an exact hit for our purposes.
        //
        // Guarded by length first, and it is worth more than it looks. A
        // substring is never longer in UTF-8 than the string it sits in, so a
        // phrase longer than the transcript cannot possibly be contained in it
        // — and `utf8.count` is a stored length rather than a walk. Most
        // phrases are longer than "open chrome", so most of them now settle
        // this in a comparison instead of a search.
        if p.utf8Count <= h.utf8Count, h.text.contains(p.text) { return 0.97 }

        let window = bestWindowSimilarity(h, needle: p, atLeast: bar)
        // Coverage is the looser signal, so it can't score as high on its own.
        let coverage = tokenCoverage(h, needle: p, atLeast: bar / 0.92) * 0.92
        return max(window, coverage)
    }

    /// Slide a word-aligned window roughly the length of the phrase across the
    /// transcript and keep the best edit-distance similarity.
    private static func bestWindowSimilarity(_ h: Haystack, needle: Needle,
                                             atLeast bar: Double) -> Double {
        let target = needle.characters[...]
        guard h.wordCount > 0, !target.isEmpty else { return 0 }

        // A window shorter than `bar` of the phrase can never reach it: an edit
        // distance is never smaller than the difference in length. Raising the
        // floor removes windows that could not have won, and never one that
        // could. The ceiling is left where it was — the cutoff below makes an
        // over-long window cost nothing anyway.
        let floor = bar > 0
            ? max(target.count / 2, Int((bar * Double(target.count)).rounded(.up)))
            : target.count / 2
        let ceiling = Int(Double(target.count) * 1.4)

        // The longest window there is, is the whole transcript. If even that
        // falls short of the floor, no window can clear the bar and the nested
        // walk below would build every one of them to prove it — which for a
        // rambling sentence is sixty-odd slices per phrase, for nothing.
        guard h.characters >= floor else { return 0 }

        var best = 0.0
        for start in 0..<h.wordCount {
            // Grows with the window, one OR per word.
            var windowMask: UInt64 = 0
            for end in start..<h.wordCount {
                windowMask |= h.wordMask(end)
                let window = h.window(start, end)
                if window.count >= floor {
                    // Nothing below the bar, or below what has already been
                    // found, can change the answer — so the distance only has to
                    // be exact while it is still small enough to matter.
                    let longest = max(window.count, target.count)
                    // The slack is for the boundary: a window that lands exactly
                    // on the bar still counts, and `(1 - 0.72) * 25` comes out a
                    // hair under seven in binary.
                    let cutoff = Int((1 - max(bar, best)) * Double(longest) + 1e-9)
                    // Every character the phrase needs and this window hasn't
                    // got costs at least one edit, and no single edit supplies
                    // two of them — so if there are more of those than the
                    // cutoff allows, the matrix cannot come back small enough
                    // and there is no point filling it in. On a rambling
                    // sentence against a hundred-odd phrases this is most of
                    // the work: three thousand distance calls became a few
                    // hundred, and the answer is the same one.
                    if (needle.mask & ~windowMask).nonzeroBitCount <= cutoff {
                        let distance = levenshtein(window, target, limit: cutoff)
                        if distance <= cutoff {
                            best = max(best, 1.0 - Double(distance) / Double(longest))
                        }
                    }
                }
                if window.count > ceiling { break }
            }
        }
        return best
    }

    /// Fraction of the phrase's words that show up in the transcript, allowing
    /// one typo per word for words of four letters or more.
    private static func tokenCoverage(_ h: Haystack, needle: Needle,
                                      atLeast bar: Double) -> Double {
        let need = needle.words
        guard !need.isEmpty else { return 0 }

        // The most misses that could still clear the bar. Once more than this
        // many words are missing the answer cannot get there, whatever is left.
        let allowedMisses = bar <= 0 ? need.count
            : need.count - Int((bar * Double(need.count) - 1e-9).rounded(.up))

        var hits = 0
        var misses = 0
        for (position, token) in need.enumerated() {
            let budget = token.count >= 4 ? 1 : 0
            let tokenMask = needle.wordMasks[position]
            var found = false
            for index in 0..<h.wordCount {
                let word = h.word(index)
                // An edit distance is never smaller than the difference in
                // length, so a word the budget can't cover on length alone
                // skips the matrix — and the same is true of a character the
                // token needs that the word simply hasn't got.
                guard abs(word.count - token.count) <= budget,
                      (tokenMask & ~h.wordMask(index)).nonzeroBitCount <= budget,
                      levenshtein(word, token[...], limit: budget) <= budget
                else { continue }
                found = true
                break
            }
            if found {
                hits += 1
            } else {
                misses += 1
                if misses > allowedMisses { return Double(hits) / Double(need.count) }
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
        return levenshtein(Array(spoken)[...], Array(expected)[...], limit: 1) <= 1
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        levenshtein(Array(a)[...], Array(b)[...], limit: max(a.count, b.count))
    }

    /// Levenshtein distance, exact up to `limit` and reported as `limit + 1`
    /// beyond it.
    ///
    /// The caller always has a score it would need to beat, and a score is
    /// `1 - distance / length` — so every comparison comes with a distance
    /// past which the answer stops mattering. Only the diagonal band that
    /// could still land inside it is filled in, and a row whose cheapest cell
    /// has already exceeded the limit ends the walk: two strings with nothing
    /// in common now cost a row or two rather than the whole matrix.
    private static func levenshtein(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>,
                                    limit: Int) -> Int {
        let over = limit + 1
        if limit < 0 { return over }
        if a.isEmpty { return min(b.count, over) }
        if b.isEmpty { return min(a.count, over) }
        if abs(a.count - b.count) > limit { return over }

        let m = b.count
        let aBase = a.startIndex
        let bBase = b.startIndex
        var prev = [Int](repeating: over, count: m + 2)
        var cur = [Int](repeating: over, count: m + 2)
        for j in 0...min(m, limit) { prev[j] = j }

        for i in 1...a.count {
            let low = max(1, i - limit)
            let high = min(m, i + limit)
            if low > high { return over }
            // The cell to the left of the band, and the one past its right end,
            // are read by this row and the next: neither is filled in by the
            // walk itself, so both are pinned out of reach here.
            cur[low - 1] = low == 1 ? i : over
            var rowBest = over
            let ai = a[aBase + i - 1]
            for j in low...high {
                let cost = ai == b[bBase + j - 1] ? 0 : 1
                let step = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                let value = min(step, over)
                cur[j] = value
                if value < rowBest { rowBest = value }
            }
            cur[high + 1] = over
            if rowBest > limit { return over }
            swap(&prev, &cur)
        }
        return min(prev[m], over)
    }
}
