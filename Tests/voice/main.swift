import AVFoundation
import Foundation

var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

Prefs.registerDefaults()   // otherwise every Bool preference reads false
print("=== what's installed ===")
let all = AVSpeechSynthesisVoice.speechVoices()
let better = all.filter { $0.quality != .default }
print("  \(all.count) voices, \(better.count) enhanced/premium")
if better.isEmpty {
    print("  NOTE: only compact voices installed — the app will say so in its menu")
}

print("\n=== ranking prefers quality, then a British accent ===")
let english = VoiceBox.englishVoices()
check("english voices found", !english.isEmpty, "\(english.count)")
let top = english.first
check("top pick is English", top?.language.hasPrefix("en") == true, top?.language ?? "nil")
check("top pick is not a novelty voice",
      !(top?.identifier.contains("com.apple.speech.synthesis.voice") ?? true)
        && !(top?.identifier.contains("eloquence") ?? true),
      top?.identifier ?? "nil")
print("  top pick: \(top?.name ?? "-") (\(top?.language ?? "-"))")

// Ranking is ordering logic, so check it holds regardless of what's installed.
if let daniel = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel"),
   let novelty = AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.Bubbles") {
    check("a real voice outranks a novelty one",
          VoiceBox.rank(daniel) > VoiceBox.rank(novelty),
          "\(VoiceBox.rank(daniel)) vs \(VoiceBox.rank(novelty))")
}
if let gb = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel"),
   let us = AVSpeechSynthesisVoice(identifier: "com.apple.voice.super-compact.en-US.Samantha") {
    check("British outranks American at equal quality",
          VoiceBox.rank(gb) > VoiceBox.rank(us), "\(VoiceBox.rank(gb)) vs \(VoiceBox.rank(us))")
}

print("\n=== the synthesiser actually produces audio, and it converts ===")
let synth = AVSpeechSynthesizer()
let utterance = AVSpeechUtterance(string: "Welcome home, sir.")
utterance.voice = VoiceBox.currentVoice()
utterance.rate = 0.46

var raw: [AVAudioPCMBuffer] = []
var floats: [AVAudioPCMBuffer] = []
var done = false
synth.write(utterance) { buffer in
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    if pcm.frameLength == 0 { done = true; return }
    raw.append(pcm)
    if let f = VoiceBox.asFloat(pcm) { floats.append(f) }
}
let start = Date()
while !done && Date().timeIntervalSince(start) < 10 {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
check("synthesis finished", done)
check("produced audio buffers", !raw.isEmpty, "\(raw.count) buffers")
check("every buffer converted to float", floats.count == raw.count, "\(floats.count)/\(raw.count)")
if let f = floats.first {
    check("converted format is float32", f.format.commonFormat == .pcmFormatFloat32,
          "\(f.format.commonFormat.rawValue)")
    check("frame count preserved", f.frameLength == raw.first!.frameLength)
}

// Silence would mean the chain plays nothing audible.
var peak: Float = 0
for b in floats {
    guard let data = b.floatChannelData else { continue }
    for i in 0..<Int(b.frameLength) { peak = max(peak, abs(data[0][i])) }
}
check("converted audio is not silent", peak > 0.01, String(format: "peak %.3f", peak))
let totalFrames = floats.reduce(0) { $0 + Int($1.frameLength) }
let seconds = Double(totalFrames) / (floats.first?.format.sampleRate ?? 22050)
check("length is plausible for the phrase", seconds > 0.5 && seconds < 6,
      String(format: "%.2fs", seconds))

print("\n=== the effects graph actually connects ===")
// Wiring the graph with the synthesiser's own format (mono 22 kHz) made
// AVAudioEngine.connect throw and took the whole app down. Build it for real.
let format = VoiceBox.shared.renderFormat()
check("a render format is available", format != nil,
      format.map { "\(Int($0.sampleRate)) Hz, \($0.channelCount)ch" } ?? "nil")
check("render format is stereo float", format?.channelCount == 2
        && format?.commonFormat == .pcmFormatFloat32)
check("chain connects without throwing", VoiceBox.shared.prepareChain())
check("connecting twice is a no-op", VoiceBox.shared.prepareChain())

print("\n=== joining and resampling ===")
if let joined = VoiceBox.join(floats) {
    let expected = floats.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
    check("joined buffer keeps every frame", joined.frameLength == expected,
          "\(joined.frameLength) vs \(expected)")
    check("joined buffer keeps the source format", joined.format == floats.first!.format)

    if let target = format, let out = VoiceBox.resample(joined, to: target) {
        let ratio = target.sampleRate / joined.format.sampleRate
        let want = Double(joined.frameLength) * ratio
        let drift = abs(Double(out.frameLength) - want) / want
        check("resampled to the output rate", out.format.sampleRate == target.sampleRate,
              "\(Int(out.format.sampleRate)) Hz")
        check("resampled length matches the rate ratio", drift < 0.05,
              String(format: "%.1f%% off", drift * 100))
        var p2: Float = 0
        if let d = out.floatChannelData {
            for i in 0..<Int(out.frameLength) { p2 = max(p2, abs(d[0][i])) }
        }
        check("resampled audio is not silent", p2 > 0.01, String(format: "peak %.3f", p2))
    } else {
        check("resample produced a buffer", false)
    }
} else {
    check("join produced a buffer", false)
}

print("\n=== a line is spoken once, not twice ===")
// AVSpeechSynthesizer.write delivers its zero-length end marker twice, which
// scheduled the audio twice and spoke every reply again.
var terminators = 0
let counter = AVSpeechSynthesizer()
let probe = AVSpeechUtterance(string: "Testing.")
probe.voice = VoiceBox.currentVoice()
counter.write(probe) { buf in
    if let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength == 0 { terminators += 1 }
}
let t0 = Date()
while Date().timeIntervalSince(t0) < 4 {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
print("   end markers delivered by AVFoundation: \(terminators)")

let before = VoiceBox.shared.playCount
VoiceBox.shared.speak("Welcome home, sir.")
let t1 = Date()
while Date().timeIntervalSince(t1) < 6 {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
let played = VoiceBox.shared.playCount - before
check("speak() plays exactly once", played == 1, "played \(played)x")

print("\n\(failures == 0 ? "ALL VOICE TESTS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
