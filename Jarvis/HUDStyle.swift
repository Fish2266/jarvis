import AppKit

/// Shared palette and helpers for the heads-up display.
enum HUD {

    static let cyan     = CGColor(red: 0.35, green: 0.91, blue: 1.00, alpha: 1)
    static let cyanSoft = CGColor(red: 0.35, green: 0.91, blue: 1.00, alpha: 0.45)
    static let cyanMid  = CGColor(red: 0.35, green: 0.91, blue: 1.00, alpha: 0.78)
    static let cyanFaint = CGColor(red: 0.35, green: 0.91, blue: 1.00, alpha: 0.18)
    static let gold     = CGColor(red: 1.00, green: 0.78, blue: 0.32, alpha: 1)
    static let amber    = CGColor(red: 1.00, green: 0.58, blue: 0.18, alpha: 1)
    static let white    = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// Neon bloom. Cheap enough for a two-second animation.
    static func glow(_ layer: CALayer, color: CGColor, radius: CGFloat, opacity: Float = 0.9) {
        layer.shadowColor = color
        layer.shadowRadius = radius
        layer.shadowOpacity = opacity
        layer.shadowOffset = .zero
    }

    static func text(_ string: String, size: CGFloat, weight: NSFont.Weight,
                     color: CGColor, kern: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
            .kern: kern,
        ])
    }

    static func label(size: CGFloat, weight: NSFont.Weight = .medium) -> CATextLayer {
        let layer = CATextLayer()
        layer.alignmentMode = .center
        layer.truncationMode = .end
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.fontSize = size
        return layer
    }

    /// Soft white dot used as the particle sprite for the burst.
    static func particleImage(diameter: CGFloat = 16) -> CGImage? {
        let side = Int(diameter)
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0.6, green: 0.95, blue: 1, alpha: 0.5),
            CGColor(red: 0.4, green: 0.9, blue: 1, alpha: 0),
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors, locations: [0, 0.4, 1])
        else { return nil }

        let mid = CGPoint(x: diameter / 2, y: diameter / 2)
        ctx.drawRadialGradient(gradient, startCenter: mid, startRadius: 0,
                               endCenter: mid, endRadius: diameter / 2, options: [])
        return ctx.makeImage()
    }

    /// The sample rate the microphone is actually running at.
    ///
    /// Set by the listener when it starts, so the readout in the corner of the
    /// HUD can say the real number instead of a plausible one. Zero until then,
    /// which the readout renders as a dash rather than as "0.0 kHz".
    static var audioRate: Double = 0

    /// How long the reticle has to cover before the next level arrives.
    ///
    /// Levels come from the clap detector every 2048 samples, so the interval
    /// depends on the input's sample rate — 43 ms at 48 kHz, 46 at 44.1. The
    /// dot animates over slightly more than that, so consecutive animations
    /// overlap and the motion never has a gap to stutter across.
    ///
    /// Set by the listener, which is the one place that knows both numbers.
    /// Kept here as a plain value rather than computed from `ClapDetector` so
    /// that drawing code depends on nothing that listens.
    static var levelInterval: TimeInterval = 1.0 / 23.0

    /// Turns a high-passed RMS into something to draw with, 0…1.
    ///
    /// The curve matters more than the scale. Speech is mostly quiet with brief
    /// loud peaks, and drawn linearly it sits flat on the floor and twitches
    /// only on plosives — the same reason the answer strip's envelope is
    /// curved. The ceiling is a little under the quietest clap threshold, so
    /// talking fills the dot without a clap being the only thing that can.
    static func voiceScale(_ rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        return CGFloat(min(1, powf(min(1, rms / 0.05), 0.6)))
    }

    /// How quickly the reticle's dot follows a rise, and a fall.
    ///
    /// Asymmetric on purpose: a voice starting is worth showing promptly, a
    /// voice stopping is not worth chasing down through every gap between
    /// syllables. Neither is 1, which is what the first version used for a
    /// rise — snapping to each frame tracked the noise in the signal rather
    /// than the voice in it.
    static let voiceAttack: CGFloat = 0.6
    static let voiceRelease: CGFloat = 0.18

    /// One step of the filter behind the dot.
    ///
    /// Pulled out of the view so it can be measured: `Tests/answers` runs a
    /// synthetic speech envelope through it and checks the frame-to-frame
    /// jerk actually falls.
    static func smoothed(_ current: CGFloat, towards target: CGFloat) -> CGFloat {
        current + (target - current) * (target > current ? voiceAttack : voiceRelease)
    }

    /// Applies contentsScale down the tree so vectors stay crisp on Retina.
    static func applyScale(_ scale: CGFloat, to layer: CALayer) {
        layer.contentsScale = scale
        if let text = layer as? CATextLayer { text.contentsScale = scale }
        layer.sublayers?.forEach { applyScale(scale, to: $0) }
    }
}
