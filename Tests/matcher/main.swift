import Foundation

// The matcher now stops measuring as soon as it can tell the answer is below
// what the caller would accept, and the edit distance fills in only the band
// that could still land inside the limit. Both are supposed to be invisible:
// the same commands resolve, with the same confidence. This proves it, against
// a plain textbook implementation and across a generated corpus.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

/// The straightforward full-matrix Levenshtein this replaced.
func reference(_ a: [Character], _ b: [Character]) -> Int {
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

// A deterministic generator, so a failure is reproducible.
var seed: UInt64 = 0x9E3779B97F4A7C15
func random(_ bound: Int) -> Int {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Int(seed % UInt64(bound))
}
let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
func word(_ length: Int) -> String {
    String((0..<length).map { _ in alphabet[random(alphabet.count)] })
}
func sentence(_ words: Int) -> String {
    (0..<words).map { _ in word(1 + random(9)) }.joined(separator: " ")
}

print("=== the edit distance agrees with the textbook one ===")
var mismatches = 0
var checked = 0
for _ in 0..<4000 {
    let a = Array(word(1 + random(14)))
    let b = Array(word(1 + random(14)))
    checked += 1
    if PhraseMatcher.editDistance(String(a), String(b)) != reference(a, b) { mismatches += 1 }
}
check("editDistance matches the full matrix on \(checked) random pairs", mismatches == 0,
      "\(mismatches) differed")

// Near-misses matter more than random pairs: that is where the band is tight.
mismatches = 0
for _ in 0..<4000 {
    var a = Array(word(4 + random(10)))
    var b = a
    for _ in 0...random(4) {
        guard !b.isEmpty else { break }
        switch random(3) {
        case 0: b[random(b.count)] = alphabet[random(alphabet.count)]
        case 1: b.remove(at: random(b.count))
        default: b.insert(alphabet[random(alphabet.count)], at: random(b.count))
        }
    }
    if random(6) == 0 { a.reverse() }
    if PhraseMatcher.editDistance(String(a), String(b)) != reference(a, b) { mismatches += 1 }
}
check("editDistance matches on 4000 deliberate near-misses", mismatches == 0,
      "\(mismatches) differed")

print("\n=== scoring with a bar never changes an answer that clears it ===")
// The contract: given `bar`, any true score at or above it comes back exactly,
// and any score below it comes back below it. Nothing more is promised, and
// nothing more is relied on.
var wrong = 0
var reported = 0
var exercised = 0
for _ in 0..<3000 {
    let haystackText = sentence(1 + random(9))
    // Half the needles are lifted from the haystack, so real matches happen.
    let needle: String
    if random(2) == 0, !haystackText.isEmpty {
        let words = haystackText.split(separator: " ")
        let from = random(words.count)
        let count = 1 + random(min(3, words.count - from))
        var lifted = words[from..<(from + count)].joined(separator: " ")
        if random(3) == 0, !lifted.isEmpty {
            var characters = Array(lifted)
            characters[random(characters.count)] = alphabet[random(alphabet.count)]
            lifted = String(characters)
        }
        needle = lifted
    } else {
        needle = sentence(1 + random(3))
    }

    let hay = PhraseMatcher.Haystack(haystackText)
    let exact = PhraseMatcher.scoreNormalized(haystackText, needle)
    for bar in [0.0, 0.5, 0.72, 0.8, 0.9, 0.95] {
        exercised += 1
        let barred = PhraseMatcher.scoreNormalized(hay, needle, atLeast: bar)
        if exact >= bar {
            if barred != exact { wrong += 1 }
        } else if barred >= bar {
            reported += 1
        }
    }
}
check("every score at or above the bar is exact (\(exercised) comparisons)", wrong == 0,
      "\(wrong) differed")
check("no score below the bar is reported as clearing it", reported == 0,
      "\(reported) overstated")

print("\n=== similarity, which the app index uses, keeps the same contract ===")
wrong = 0
reported = 0
for _ in 0..<3000 {
    let name = sentence(1 + random(3))
    let target = random(2) == 0 ? String(name.prefix(1 + random(name.count))) : sentence(1 + random(2))
    let hay = PhraseMatcher.Haystack(name)
    let exact = PhraseMatcher.similarityNormalized(name, target)
    for bar in [0.0, 0.72, 0.8, 0.9] {
        let barred = PhraseMatcher.similarity(hay, target, atLeast: bar)
        if exact >= bar {
            if barred != exact { wrong += 1 }
        } else if barred >= bar {
            reported += 1
        }
    }
}
check("every similarity at or above the bar is exact", wrong == 0, "\(wrong) differed")
check("no similarity below the bar is reported as clearing it", reported == 0,
      "\(reported) overstated")

print("\n=== the boundary, where a score lands exactly on the threshold ===")
// A window whose distance puts it precisely on the threshold has to count.
// This is the case binary floating point gets wrong if the cutoff is worked
// out carelessly: (1 - 0.72) * 25 comes out a hair under seven.
//
// Built rather than found: a haystack of one long word and a needle the same
// length differing in exactly the number of characters that lands the score on
// the bar. Containment and coverage both miss, so the window walk decides it.
for (bar, longest) in [(0.72, 25), (0.72, 50), (0.8, 20), (0.8, 45), (0.9, 30), (0.95, 20)] {
    let distance = Int((1 - bar) * Double(longest) + 0.5)
    guard distance >= 1, distance < longest else { continue }
    let haystack = String(repeating: "a", count: longest)
    let needle = String(repeating: "a", count: longest - distance)
        + String(repeating: "b", count: distance)
    let exact = PhraseMatcher.scoreNormalized(haystack, needle)
    let barred = PhraseMatcher.scoreNormalized(PhraseMatcher.Haystack(haystack), needle,
                                               atLeast: exact)
    check(String(format: "a score of %.4f survives being asked for exactly itself", exact),
          barred == exact, String(format: "%.17g vs %.17g", exact, barred))
    // And the resolver's own comparison still lets it through.
    if abs(exact - bar) < 1e-9 {
        check(String(format: "  %.4f still counts as reaching the %.2f threshold", exact, bar),
              barred >= bar)
    }
}

print("\n=== a haystack is the same text however it is sliced ===")
for text in ["", "one", "one two", "a bb ccc dddd", sentence(12)] {
    let hay = PhraseMatcher.Haystack(text)
    check("\"\(text.prefix(24))\" round-trips", hay.text == text)
    check("  and scores itself 1.0", text.isEmpty
          || PhraseMatcher.scoreNormalized(hay, text, atLeast: 0) == 1.0)
}

print("\n=== token runs agree with the split-every-time version ===")
mismatches = 0
for _ in 0..<2000 {
    let haystack = sentence(1 + random(6))
    let words = haystack.split(separator: " ")
    let needle = random(2) == 0 && !words.isEmpty
        ? words[random(words.count)...].prefix(1 + random(2)).joined(separator: " ")
        : sentence(1 + random(2))
    let viaString = PhraseMatcher.containsTokenRun(haystack, needle)
    let viaHaystack = PhraseMatcher.containsTokenRun(PhraseMatcher.Haystack(haystack), needle)
    if viaString != viaHaystack { mismatches += 1 }
}
check("both spellings of containsTokenRun agree", mismatches == 0, "\(mismatches) differed")

print("\n=== what it costs, which is the point of all of it ===")
// Printed rather than asserted tightly: this runs on the main thread for every
// partial transcript, so the shape of the numbers is what matters. The bound is
// loose enough not to flake on a busy machine and tight enough to catch the
// accidental reintroduction of a full matrix or a per-phrase re-split.
let macros = Macro.seeded()
_ = AppIndex.shared.refresh()
let spoken = [
    "open chrome",
    "jarvis open chrome on work",
    "start up the craft",
    "bring over xcode",
    "open a new gmail tab",
    "what is the capital of france",
    "i could really go for some blocky building right about now",
]
// Prepared once, which is what the listener does: the catalog is rebuilt only
// when you edit your commands, never per transcript. Measuring the convenience
// overload instead would be measuring the preparation a few dozen times a
// sentence, which is precisely the cost this arrangement removes.
let catalog = Resolver.Catalog(macros)
var worst = 0.0
for phrase in spoken {
    for _ in 0..<50 { _ = Resolver.resolveFast(transcript: phrase, catalog: catalog) }
    let began = CFAbsoluteTimeGetCurrent()
    for _ in 0..<200 { _ = Resolver.resolveFast(transcript: phrase, catalog: catalog) }
    let each = (CFAbsoluteTimeGetCurrent() - began) / 200 * 1e6
    worst = max(worst, each)
    print(String(format: "   %6.0f µs  \"%@\"", each, phrase as NSString))
}
print("   (\(AppIndex.shared.entries.count) apps indexed, "
      + "\(macros.reduce(0) { $0 + $1.phrases.count }) phrases)")
check("the slowest phrase still resolves in well under 3 ms",
      worst < 3000, String(format: "%.0f µs", worst))

// Preparing the phrases is the whole point, so it has to actually be cheaper.
let unpreparedBegan = CFAbsoluteTimeGetCurrent()
for _ in 0..<200 { _ = Resolver.resolveFast(transcript: "open chrome", macros: macros) }
let unprepared = (CFAbsoluteTimeGetCurrent() - unpreparedBegan) / 200 * 1e6
let preparedBegan = CFAbsoluteTimeGetCurrent()
for _ in 0..<200 { _ = Resolver.resolveFast(transcript: "open chrome", catalog: catalog) }
let prepared = (CFAbsoluteTimeGetCurrent() - preparedBegan) / 200 * 1e6
print(String(format: "   preparing phrases per call costs %.0f µs; prepared once, %.0f µs",
             unprepared, prepared))
check("a prepared catalog is materially cheaper than re-splitting every call",
      prepared < unprepared * 0.7, String(format: "%.0f vs %.0f µs", prepared, unprepared))

// The two paths are the same function with the same inputs, so they must agree
// on every answer — a fast path that resolves differently is not a fast path.
for phrase in spoken + ["mute", "next track", "cancel the timer", "quit chrome",
                        "lock the screen", "search for tide times", "hello there"] {
    let a = Resolver.resolveFast(transcript: phrase, macros: macros)
    let b = Resolver.resolveFast(transcript: phrase, catalog: catalog)
    check("prepared and unprepared agree on \"\(phrase)\"",
          a?.macro.name == b?.macro.name && a?.confidence == b?.confidence
            && a?.payload == b?.payload,
          "\(a?.macro.name ?? "nothing") vs \(b?.macro.name ?? "nothing")")
}

print(failures == 0 ? "\nALL MATCHER TESTS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
