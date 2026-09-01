import Foundation

let sr = 48000.0
var failures = 0

func check(_ label: String, _ pass: Bool, _ detail: String = "") {
    print("\(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  [\(detail)]")")
    if !pass { failures += 1 }
}

// ---------- synthetic audio ----------

func noise(_ amp: Float) -> Float { Float.random(in: -amp...amp) }

/// Impulsive broadband burst with a fast exponential decay — a stand-in for a clap.
func clapBurst(peak: Float, tau: Double) -> [Float] {
    let n = Int(0.25 * sr)
    return (0..<n).map { i in
        let t = Double(i) / sr
        return noise(peak) * Float(exp(-t / tau)) + noise(0.002)
    }
}

func silence(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * sr)).map { _ in noise(0.002) }
}

/// Sharp onset but sustained — music, a door slam with reverb, a shout.
func sustained(peak: Float, seconds: Double) -> [Float] {
    (0..<Int(seconds * sr)).map { _ in noise(peak) }
}

func run(_ stream: [Float], sensitivity: Sensitivity = .medium)
    -> (claps: Int, doubles: Int, rejects: Int) {
    let d = ClapDetector()
    d.config = sensitivity.config
    var claps = 0, doubles = 0, rejects = 0
    d.onClap = { _ in claps += 1 }
    d.onDoubleClap = { doubles += 1 }
    d.onRejected = { _ in rejects += 1 }
    stream.withUnsafeBufferPointer { buf in
        // Feed it the way AVAudioEngine would: 1024-frame chunks.
        var offset = 0
        while offset < buf.count {
            let n = min(1024, buf.count - offset)
            d.process(buf.baseAddress! + offset, count: n, sampleRate: sr)
            offset += n
        }
    }
    return (claps, doubles, rejects)
}

print("=== ClapDetector ===")

let quiet = silence(2.0)

// 1. Two claps 300 ms apart.
var stream = quiet + clapBurst(peak: 0.8, tau: 0.008)
stream += silence(0.05)                                   // 250 ms burst + 50 ms = 300 ms gap
stream += clapBurst(peak: 0.8, tau: 0.008) + silence(0.5)
var r = run(stream)
check("double clap at 300 ms gap fires once", r.doubles == 1 && r.claps == 2,
      "claps=\(r.claps) doubles=\(r.doubles)")

// 2. Two claps ~1.5 s apart: too slow, should stay two singles.
stream = quiet + clapBurst(peak: 0.8, tau: 0.008) + silence(1.3)
      + clapBurst(peak: 0.8, tau: 0.008) + silence(0.5)
r = run(stream)
check("claps 1.5 s apart do not fire", r.doubles == 0 && r.claps == 2,
      "claps=\(r.claps) doubles=\(r.doubles)")

// 3. Sustained loud noise must be rejected, not counted.
stream = quiet + sustained(peak: 0.6, seconds: 1.0) + silence(0.5)
r = run(stream)
check("1 s of sustained noise fires nothing", r.doubles == 0 && r.claps == 0,
      "claps=\(r.claps) rejects=\(r.rejects)")

// 4. Speech-ish: several sustained bursts in a row.
stream = quiet
for _ in 0..<6 { stream += sustained(peak: 0.35, seconds: 0.22) + silence(0.08) }
r = run(stream)
check("babbling bursts fire nothing", r.doubles == 0, "claps=\(r.claps) doubles=\(r.doubles)")

// 5. A quiet room with only ambient noise.
r = run(silence(5.0))
check("5 s of silence fires nothing", r.claps == 0 && r.doubles == 0, "claps=\(r.claps)")

// 6. Quiet claps still land on High sensitivity, and are ignored on Low.
stream = quiet + clapBurst(peak: 0.10, tau: 0.008) + silence(0.05)
      + clapBurst(peak: 0.10, tau: 0.008) + silence(0.5)
let high = run(stream, sensitivity: .high)
let low  = run(stream, sensitivity: .low)
check("distant clap caught on High", high.doubles == 1, "doubles=\(high.doubles)")
check("distant clap ignored on Low", low.doubles == 0, "doubles=\(low.doubles)")

// 7. Three claps in a row: fires on the second, not again on the third.
stream = quiet
for _ in 0..<3 { stream += clapBurst(peak: 0.8, tau: 0.008) + silence(0.05) }
r = run(stream + silence(0.5))
check("three claps fire exactly once", r.doubles == 1, "doubles=\(r.doubles)")

// 8. Talking, then a pause, then a real double clap.
stream = quiet
for _ in 0..<4 { stream += sustained(peak: 0.35, seconds: 0.22) + silence(0.08) }
stream += silence(0.4)
stream += clapBurst(peak: 0.8, tau: 0.008) + silence(0.05)
stream += clapBurst(peak: 0.8, tau: 0.008) + silence(0.5)
r = run(stream)
check("double clap right after talking still fires", r.doubles == 1, "claps=\(r.claps) doubles=\(r.doubles)")

// 9. Music-ish: loud notes with short rests.
stream = quiet
for _ in 0..<10 { stream += sustained(peak: 0.5, seconds: 0.35) + silence(0.12) }
r = run(stream)
check("sustained notes with rests fire nothing", r.doubles == 0, "claps=\(r.claps) doubles=\(r.doubles)")

print("\n=== PhraseMatcher ===")

let target = "wake up daddy's home"
let shouldMatch = [
    "wake up daddy's home",
    "Wake up, Daddy's home!",
    "wake up daddies home",
    "wake up daddy home",
    "so I said wake up daddy's home",
    "wake up daddy's home now",
    "wakeup daddys home",
]
let shouldNotMatch = [
    "what's the weather today",
    "wake up",
    "hey can you open my email",
    "wait what's for dinner",
    "I'm going home",
    "",
]

for s in shouldMatch {
    check("matches \"\(s)\"", PhraseMatcher.matches(transcript: s, phrase: target))
}
for s in shouldNotMatch {
    check("rejects \"\(s)\"", !PhraseMatcher.matches(transcript: s, phrase: target))
}

print("\n\(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
