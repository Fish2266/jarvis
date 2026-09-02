import Accelerate
import AVFoundation
import AppKit

/// Speech output: picks the best installed voice, then runs it through a small
/// on-device effects chain so it sounds like a room rather than a phone speaker.
///
/// Everything here is local — Apple's voices are free downloads and the effects
/// are AVAudioEngine units. No network, no account, no per-word cost.
final class VoiceBox {

    static let shared = VoiceBox()

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 3)
    private let reverb = AVAudioUnitReverb()
    private var wiredFormat: AVAudioFormat?
    /// Bumped whenever speech is started or stopped.
    ///
    /// A line is synthesised before it is played, and `stop` could only silence
    /// what was already playing — so pressing Escape while the reply was still
    /// being written would silence nothing, and the line arrived a moment later
    /// anyway. The render checks this before it reaches the speaker.
    private var speakID = 0
    /// Whether the nodes are on the engine. Separate from `wiredFormat`, which
    /// only says what they were last connected at: `resetChain` clears the
    /// format to force a re-connect, and must not re-attach along with it.
    private var nodesAttached = false

    private init() {}

    // MARK: - Choosing a voice

    /// Higher is better: quality dominates, then a British accent, then male.
    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        switch voice.quality {
        case .premium: score += 400
        case .enhanced: score += 300
        default: score += 100
        }
        switch voice.language {
        case "en-GB": score += 40
        case "en-IE", "en-AU", "en-ZA": score += 20
        default: score += voice.language.hasPrefix("en") ? 10 : 0
        }
        if voice.gender == .male { score += 5 }
        // Novelty voices ("Bad News", "Bubbles") are not butlers.
        if voice.identifier.contains("com.apple.speech.synthesis.voice") { score -= 200 }
        if voice.identifier.contains("eloquence") { score -= 150 }
        return score
    }

    /// Apple's joke voices, which are never what you want for this.
    static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.contains("com.apple.speech.synthesis.voice")
            || voice.identifier.contains("eloquence")
    }

    /// Everything installed, grouped for the menu: premium and enhanced first,
    /// then plain English, then the rest.
    static func grouped() -> (premium: [AVSpeechSynthesisVoice],
                              enhanced: [AVSpeechSynthesisVoice],
                              english: [AVSpeechSynthesisVoice],
                              other: [AVSpeechSynthesisVoice]) {
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { !isNovelty($0) }
            .map { (voice: $0, rank: rank($0)) }
        // Ranked once each rather than twice per comparison inside the sort.
        let byRank = { (a: (voice: AVSpeechSynthesisVoice, rank: Int),
                        b: (voice: AVSpeechSynthesisVoice, rank: Int)) in a.rank > b.rank }
        let premium = all.filter { $0.voice.quality == .premium }.sorted(by: byRank)
        let enhanced = all.filter { $0.voice.quality == .enhanced }.sorted(by: byRank)
        let rest = all.filter { $0.voice.quality == .default }
        return (premium.map(\.voice), enhanced.map(\.voice),
                rest.filter { $0.voice.language.hasPrefix("en") }.sorted(by: byRank).map(\.voice),
                rest.filter { !$0.voice.language.hasPrefix("en") }
                    .sorted { $0.voice.language < $1.voice.language }.map(\.voice))
    }

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .map { (voice: $0, rank: rank($0)) }
            .sorted { $0.rank > $1.rank }
            .map(\.voice)
    }

    /// Your pick if it's still installed, otherwise the best thing available.
    static func currentVoice() -> AVSpeechSynthesisVoice? {
        if let saved = Prefs.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: saved) {
            return voice
        }
        return englishVoices().first
    }

    /// True when nothing better than the built-in compact voices is installed.
    static var onlyCompactVoicesInstalled: Bool {
        !AVSpeechSynthesisVoice.speechVoices().contains { $0.quality != .default }
    }

    // MARK: - Speaking

    /// Forces the graph to be rebuilt, so changed effect settings take hold.
    func resetChain() {
        if engine.isRunning { engine.stop() }
        wiredFormat = nil
    }

    func stop() {
        speakID &+= 1
        synth.stopSpeaking(at: .immediate)
        if player.isPlaying { player.stop() }
    }

    func speak(_ text: String) {
        guard Prefs.voiceEffects else {
            speakPlain(text)
            return
        }
        speakWithEffects(text)
    }

    // MARK: - Effects chain

    /// The format the whole chain runs at: standard float, stereo, at whatever
    /// rate the output device wants.
    ///
    /// Wiring the graph with the synthesiser's own format (mono, 22 kHz) is what
    /// made `AVAudioEngine.connect` throw — the mixer wouldn't take it.
    func renderFormat() -> AVAudioFormat? {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 48_000
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
    }

    /// Builds the graph. Returns false if the chain can't be set up, so the
    /// caller can fall back to speaking without effects.
    @discardableResult
    func prepareChain() -> Bool {
        guard let format = renderFormat() else { return false }
        if wiredFormat == format { return true }

        if engine.isRunning { engine.stop() }
        if !nodesAttached {
            engine.attach(player)
            engine.attach(eq)
            engine.attach(reverb)
            nodesAttached = true
        }

        Self.configure(eq: eq, reverb: reverb)

        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        wiredFormat = format
        return true
    }

    /// The actual effect settings, in one place so tests can measure them.
    static func configure(eq: AVAudioUnitEQ, reverb: AVAudioUnitReverb) {
        let bands = eq.bands
        bands[0].filterType = .highPass
        bands[0].frequency = 95
        bands[0].bypass = false
        bands[1].filterType = .parametric
        bands[1].frequency = 320
        bands[1].bandwidth = 1.0
        bands[1].gain = -2.5
        bands[1].bypass = false
        bands[2].filterType = .highShelf
        bands[2].frequency = 4200
        bands[2].gain = 3.5
        bands[2].bypass = false
        eq.globalGain = 1.0

        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = Float(Prefs.reverbAmount)
    }

    /// Runs audio through the same chain offline, for measurement.
    static func renderThroughEffects(_ raw: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // The effect units reject mono 22 kHz outright (-10868), which is what
        // crashed the app before. Everything runs at the standard format.
        guard let standard = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let input = resample(raw, to: standard)
        else { return nil }
        let offline = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let reverb = AVAudioUnitReverb()
        configure(eq: eq, reverb: reverb)

        offline.attach(player); offline.attach(eq); offline.attach(reverb)
        offline.connect(player, to: eq, format: input.format)
        offline.connect(eq, to: reverb, format: input.format)
        offline.connect(reverb, to: offline.mainMixerNode, format: input.format)

        let tail = AVAudioFrameCount(input.format.sampleRate * 1.5)
        guard let out = AVAudioPCMBuffer(pcmFormat: input.format,
                                         frameCapacity: input.frameLength + tail)
        else { return nil }
        do {
            try offline.enableManualRenderingMode(.offline, format: input.format,
                                                  maximumFrameCount: 4096)
            try offline.start()
        } catch { return nil }

        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        guard let scratch = AVAudioPCMBuffer(pcmFormat: offline.manualRenderingFormat,
                                             frameCapacity: 4096) else { return nil }
        while out.frameLength < out.frameCapacity {
            let want = min(AVAudioFrameCount(4096), out.frameCapacity - out.frameLength)
            do {
                let status = try offline.renderOffline(want, to: scratch)
                guard status == .success, scratch.frameLength > 0 else { break }
            } catch { break }
            guard let src = scratch.floatChannelData, let dst = out.floatChannelData
            else { break }
            for ch in 0..<Int(input.format.channelCount) {
                dst[ch].advanced(by: Int(out.frameLength))
                    .update(from: src[ch], count: Int(scratch.frameLength))
            }
            out.frameLength += scratch.frameLength
        }
        offline.stop()
        return out
    }

    /// Counts completed playbacks, so tests can prove a line is spoken once.
    private(set) var playCount = 0

    // MARK: - What the voice looks like

    /// How many envelope samples make up a second.
    static let envelopeHz: Double = 60

    /// Fired on the main queue as a rendered line starts playing: a 0…1 loudness
    /// envelope and how long the line runs. Lets the HUD draw the actual voice
    /// instead of a canned animation.
    var onPlayback: ((_ envelope: [Float], _ duration: TimeInterval) -> Void)?

    /// Loudness per envelope frame, normalised so the loudest moment is 1.
    ///
    /// One pass over a buffer we already have in hand, before a single sample is
    /// played — nothing here runs on the audio thread.
    static func envelope(of buffer: AVAudioPCMBuffer, hz: Double = envelopeHz) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0, hz > 0
        else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let step = max(1, Int(buffer.format.sampleRate / hz))

        var out: [Float] = []
        out.reserveCapacity(frames / step + 1)
        var index = 0
        while index < frames {
            let count = min(step, frames - index)
            var sum: Float = 0
            for channel in 0..<channels {
                var rms: Float = 0
                vDSP_rmsqv(data[channel] + index, 1, &rms, vDSP_Length(count))
                sum += rms
            }
            out.append(sum / Float(channels))
            index += count
        }

        // Speech is mostly quiet with short loud peaks; without the curve the
        // trace sits flat on the floor and only twitches on plosives.
        guard let peak = out.max(), peak > 0 else { return out }
        return out.map { min(1, powf($0 / peak, 0.65)) }
    }

    private func speakWithEffects(_ text: String) {
        speakID &+= 1
        let id = speakID
        let utterance = makeUtterance(text)
        var pieces: [AVAudioPCMBuffer] = []
        // AVSpeechSynthesizer.write delivers its zero-length end marker TWICE.
        // Without this guard the audio gets scheduled twice and you hear the
        // whole line spoken again.
        var finished = false

        synth.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            guard pcm.frameLength > 0 else {
                if finished { return }
                finished = true
                DispatchQueue.main.async {
                    guard id == self.speakID else { return }   // stopped meanwhile
                    guard let joined = Self.join(pieces),
                          let format = self.renderFormat(),
                          let ready = Self.resample(joined, to: format)
                    else {
                        self.speakPlain(text)     // never silently say nothing
                        return
                    }
                    self.play(ready)
                }
                return
            }
            if let float = Self.asFloat(pcm) { pieces.append(float) }
        }
    }

    /// The synthesiser hands back 16-bit buffers; the engine wants float.
    /// Same sample rate, so the simple conversion API is fine here.
    static func asFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.commonFormat == .pcmFormatFloat32 { return buffer }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount,
                                         interleaved: false),
              let converter = AVAudioConverter(from: buffer.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target,
                                         frameCapacity: buffer.frameCapacity)
        else { return nil }

        out.frameLength = buffer.frameLength
        do {
            try converter.convert(to: out, from: buffer)
            return out
        } catch {
            return nil
        }
    }

    /// One buffer from many, so the resampler runs once and keeps continuity.
    static func join(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let total = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard total > 0,
              let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: total),
              let dst = out.floatChannelData
        else { return nil }

        var offset = AVAudioFrameCount(0)
        let channels = Int(first.format.channelCount)
        for buffer in buffers {
            guard let src = buffer.floatChannelData else { continue }
            for channel in 0..<channels {
                dst[channel].advanced(by: Int(offset))
                    .update(from: src[channel], count: Int(buffer.frameLength))
            }
            offset += buffer.frameLength
        }
        out.frameLength = total
        return out
    }

    /// Rate and channel conversion. The simple `convert(to:from:)` can't change
    /// sample rate, so this uses the pull-style API.
    static func resample(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else { return nil }

        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.currentVoice()
        // A butler is unhurried: a little under the default rate and pitch.
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.92
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.05
        return utterance
    }

    private func speakPlain(_ text: String) {
        synth.speak(makeUtterance(text))
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        guard prepareChain() else { return }
        playCount += 1
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            return
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }

        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        onPlayback?(Self.envelope(of: buffer), duration)
    }

}
