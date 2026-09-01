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

    /// Applies contentsScale down the tree so vectors stay crisp on Retina.
    static func applyScale(_ scale: CGFloat, to layer: CALayer) {
        layer.contentsScale = scale
        if let text = layer as? CATextLayer { text.contentsScale = scale }
        layer.sublayers?.forEach { applyScale(scale, to: $0) }
    }
}
