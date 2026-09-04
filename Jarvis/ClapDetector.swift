import Foundation
import Accelerate

struct ClapConfig {
    /// Minimum high-passed RMS for a frame to even be considered a transient.
    var absoluteThreshold: Float
    /// How many times louder than the rolling background a frame must be.
    var attackRatio: Float
    /// How many times louder than the immediately preceding ~40 ms a frame must be.
    /// This is what separates a real attack from the tail end of a sustained sound.
    var localAttackRatio: Float = 4.0
    /// Ignore new onsets for this long after one fires.
    var refractory: Double = 0.085
    /// How long after an onset we check that the sound already died away.
    var decayDelay: Double = 0.085
    /// Energy must fall below this fraction of the onset peak to count as a clap.
    var decayRatio: Float = 0.35
    /// Allowed spacing between the two claps of a double clap.
    var minGap: Double = 0.09
    var maxGap: Double = 0.70
}

/// Detects hand claps from a mono float stream.
///
/// A clap is an impulse: near-instant attack, broadband (lots of high frequency),
/// and gone again within ~100 ms. Speech and music share the first trait but not
/// the third, so every candidate onset is held back briefly and only confirmed
/// once the energy has actually collapsed.
final class ClapDetector {

    // Callbacks fire on the audio thread — hop to main before touching UI.
    var onLevel: ((Float, Float) -> Void)?   // (rms, background)
    var onClap: ((Int) -> Void)?             // 1 = first clap, 2 = second
    var onDoubleClap: (() -> Void)?
    var onRejected: ((Float) -> Void)?       // transient that failed the decay test

    var config: ClapConfig = Sensitivity.medium.config

    private let frameSize = 256
    /// How many samples pass between level reports — eight frames of 256.
    ///
    /// Published because the HUD draws from these: the reticle's dot is only
    /// told the level this often, so it has to know how long it is being asked
    /// to cover before the next one arrives.
    static let samplesPerLevelReport = 256 * 8
    private var frame: [Float]
    private var frameFill = 0
    private var prevSample: Float = 0

    private let historySize = 8              // ~43 ms of frames preceding the current one
    private var history: [Float]
    private var historyIndex = 0

    private var background: Float = 0.001
    private var clock: Double = 0            // seconds of audio processed
    private var lastOnset: Double = -10
    private var lastConfirmed: Double?
    private var levelTick = 0

    private struct Pending {
        var time: Double
        var peak: Float
    }
    private var pending: Pending?

    init() {
        frame = [Float](repeating: 0, count: frameSize)
        history = [Float](repeating: 0, count: historySize)
    }

    func reset() {
        frameFill = 0
        prevSample = 0
        for i in history.indices { history[i] = 0 }
        historyIndex = 0
        background = 0.001
        clock = 0
        lastOnset = -10
        lastConfirmed = nil
        pending = nil
    }

    /// Forget a half-finished double clap (called when we stop listening).
    func resetSequence() {
        lastConfirmed = nil
        pending = nil
    }

    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard sampleRate > 0 else { return }
        for i in 0..<count {
            let x = samples[i]
            // One-pole differentiator: cheap high-pass, kills rumble and vowel
            // fundamentals while leaving the clap's HF crack intact.
            frame[frameFill] = x - 0.97 * prevSample
            prevSample = x
            frameFill += 1
            if frameFill == frameSize {
                frameFill = 0
                processFrame(sampleRate: sampleRate)
            }
        }
    }

    private func processFrame(sampleRate: Double) {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frameSize))
        clock += Double(frameSize) / sampleRate

        // Loudness of the frames just before this one, captured before we
        // overwrite the ring buffer at the end of this method.
        var recent: Float = 0
        vDSP_meanv(history, 1, &recent, vDSP_Length(historySize))
        recent = max(recent, 1e-5)

        // Background tracks ambient noise: rises slowly (~3 s), falls quickly (~0.3 s),
        // so a clap barely moves it but walking into a loud room re-calibrates fast.
        let alpha: Float = rms > background ? 0.0015 : 0.02
        background += (rms - background) * alpha
        background = max(background, 1e-5)

        levelTick += 1
        if levelTick >= Self.samplesPerLevelReport / frameSize {   // ~23 Hz
            levelTick = 0
            onLevel?(rms, background)
        }

        let cfg = config

        // Resolve a held onset before looking for a new one.
        if var p = pending {
            p.peak = max(p.peak, rms)
            if clock - p.time >= cfg.decayDelay {
                if rms < p.peak * cfg.decayRatio {
                    confirmClap(at: p.time, config: cfg)
                } else {
                    onRejected?(p.peak)          // sustained sound, not a clap
                }
                pending = nil
            } else {
                pending = p
            }
        }

        defer {
            history[historyIndex] = rms
            historyIndex = (historyIndex + 1) % historySize
        }

        guard pending == nil,
              clock - lastOnset > cfg.refractory,
              rms > cfg.absoluteThreshold,
              rms > background * cfg.attackRatio,
              rms > recent * cfg.localAttackRatio
        else { return }

        lastOnset = clock
        pending = Pending(time: clock, peak: rms)
    }

    private func confirmClap(at time: Double, config cfg: ClapConfig) {
        if let prev = lastConfirmed, time - prev >= cfg.minGap, time - prev <= cfg.maxGap {
            lastConfirmed = nil
            onClap?(2)
            onDoubleClap?()
        } else {
            lastConfirmed = time
            onClap?(1)
        }
    }
}
