import AppKit
import AVFoundation

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

let short = "Blue, sir."
let medium = String(repeating: "word ", count: 24)
let long = String(repeating: "word ", count: 80)

print("=== the strip sizes itself to the sentence ===")
check("short answers get the big type", Readout.fontSize(for: short) == 18)
check("long answers step down", Readout.fontSize(for: long) == 14,
      "\(Readout.fontSize(for: long))")
check("type only ever shrinks",
      Readout.fontSize(for: short) >= Readout.fontSize(for: medium)
          && Readout.fontSize(for: medium) >= Readout.fontSize(for: long))

let laptop = Readout.size(for: short, screenWidth: 1728)
let wrapped = Readout.size(for: long, screenWidth: 1728)
check("it stays a strip, not a panel", laptop.height < 160, "\(Int(laptop.height))pt")
check("a paragraph grows it but not unboundedly",
      wrapped.height > laptop.height && wrapped.height < 320, "\(Int(wrapped.height))pt")
check("never wider than a comfortable reading measure",
      Readout.width(forScreen: 5120) <= 860, "\(Readout.width(forScreen: 5120))")
check("still usable on a small screen",
      Readout.width(forScreen: 1280) <= 1280 && Readout.width(forScreen: 1280) >= 420,
      "\(Readout.width(forScreen: 1280))")
check("a narrow screen doesn't produce a strip wider than the screen",
      Readout.width(forScreen: 600) <= 600 || Readout.width(forScreen: 600) == 420,
      "\(Readout.width(forScreen: 600))")

print("\n=== how long it lingers with the sound off ===")
check("a two-word answer still gets read", Readout.readingTime("Blue, sir.") >= 3.4,
      String(format: "%.1fs", Readout.readingTime("Blue, sir.")))
check("longer answers linger longer",
      Readout.readingTime(long) > Readout.readingTime(short))
check("but never outstay their welcome", Readout.readingTime(long) <= 16,
      String(format: "%.1fs", Readout.readingTime(long)))
check("whitespace isn't counted as words",
      Readout.readingTime("a   b") == Readout.readingTime("a b"))

print("\n=== the waveform follows the voice ===")
let bars = 5
let atStart = Readout.levels(envelope: [1, 0, 0, 0, 0], playhead: 0, bars: bars)
check("nothing is drawn ahead of the playhead",
      atStart[0...3].allSatisfy { $0 == 0 } && atStart[4] > 0,
      atStart.map { String(format: "%.2f", $0) }.joined(separator: " "))
let atEnd = Readout.levels(envelope: [0, 0, 0, 0, 1], playhead: 4, bars: bars)
check("the newest sample is on the right",
      atEnd[0...3].allSatisfy { $0 == 0 } && atEnd[4] > 0)
let past = Readout.levels(envelope: [1, 1], playhead: 40, bars: bars)
check("running off the end of the line leaves it flat", past.allSatisfy { $0 == 0 })
check("no envelope means no trace",
      Readout.levels(envelope: [], playhead: 10, bars: bars).allSatisfy { $0 == 0 })
check("zero bars is not a crash", Readout.levels(envelope: [1], playhead: 0, bars: 0).isEmpty)

let flat = Readout.levels(envelope: [Float](repeating: 1, count: 200), playhead: 199, bars: 40)
check("the trace tapers into the rail rather than stopping dead",
      flat[20] > flat[0] && flat[20] > flat[39])
check("levels stay inside the bar", flat.allSatisfy { $0 >= 0 && $0 <= 1 },
      String(format: "max %.2f", flat.max() ?? 0))

print("\n=== standby wave ===")
let idleA = Readout.idleLevels(bars: 60, time: 0)
let idleB = Readout.idleLevels(bars: 60, time: 0.4)
check("it actually moves", zip(idleA, idleB).contains { abs($0 - $1) > 0.03 },
      String(format: "max delta %.3f", zip(idleA, idleB).map { abs($0 - $1) }.max() ?? 0))
check("it reads as a wave, not a bulge",
      (idleA.max() ?? 0) - (idleA.min() ?? 0) > 0.08,
      String(format: "%.2f…%.2f", idleA.min() ?? 0, idleA.max() ?? 0))
check("never loud enough to be mistaken for speech", (idleA.max() ?? 1) < 0.35,
      String(format: "%.2f", idleA.max() ?? 1))
check("zero bars is not a crash", Readout.idleLevels(bars: 0, time: 1).isEmpty)

print("\n=== peaks pick up the HUD's gold ===")
func rgb(_ c: CGColor) -> (CGFloat, CGFloat, CGFloat) {
    let c = c.components ?? [0, 0, 0]
    return (c[0], c[1], c[2])
}
check("quiet is cyan", rgb(Readout.barColor(for: 0)).2 > 0.9,
      String(format: "%.2f blue", rgb(Readout.barColor(for: 0)).2))
check("loud is gold", rgb(Readout.barColor(for: 1)).0 > 0.9 && rgb(Readout.barColor(for: 1)).2 < 0.5,
      String(format: "r %.2f b %.2f", rgb(Readout.barColor(for: 1)).0, rgb(Readout.barColor(for: 1)).2))
check("mid-level is still cyan", rgb(Readout.barColor(for: 0.4)).2 > 0.9)
check("out-of-range levels are clamped, not crashes",
      Readout.barColor(for: -5) == Readout.barColor(for: 0)
          && Readout.barColor(for: 99) == Readout.barColor(for: 1))

print("\n=== reading loudness out of the rendered voice ===")
func buffer(_ fill: (Int) -> Float, frames: Int, rate: Double = 48_000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<2 {
        for i in 0..<frames { buffer.floatChannelData![channel][i] = fill(i) }
    }
    return buffer
}

let oneSecond = buffer({ _ in 0.5 }, frames: 48_000)
let env = VoiceBox.envelope(of: oneSecond)
check("one second of audio is about sixty frames", abs(env.count - 60) <= 1, "\(env.count)")
check("a steady tone normalises to full height", env.allSatisfy { $0 > 0.99 })

let silence = VoiceBox.envelope(of: buffer({ _ in 0 }, frames: 4800))
check("silence draws nothing", silence.allSatisfy { $0 == 0 }, "\(silence.count) frames")

// Loud first half, quiet second half — the shape the bars are meant to trace.
let split = VoiceBox.envelope(of: buffer({ $0 < 24_000 ? 0.9 : 0.05 }, frames: 48_000))
check("the loud half comes out on top", (split.first ?? 0) > (split.last ?? 1),
      String(format: "%.2f then %.2f", split.first ?? 0, split.last ?? 0))
check("the peak is exactly one", abs((split.max() ?? 0) - 1) < 0.001)
check("everything stays in range", split.allSatisfy { $0 >= 0 && $0 <= 1 })
check("quiet passages are lifted clear of the floor", (split.last ?? 0) > 0.1,
      String(format: "%.2f", split.last ?? 0))

let emptyBuffer = AVAudioPCMBuffer(
    pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
    frameCapacity: 128)!
check("an empty buffer yields no envelope", VoiceBox.envelope(of: emptyBuffer).isEmpty)

print("\n\(failures == 0 ? "ALL READOUT TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
