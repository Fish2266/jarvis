import AppKit
import CoreGraphics

/// What the camera is handing Vision, with what Vision made of it drawn on top.
///
/// Mirrored, deliberately. Everything downstream of `HandTracker` is in user
/// space — x grows as you move to your right — so a mirrored preview is the one
/// arrangement where what you see and what the recogniser measures agree. An
/// unmirrored preview would show your hand going left while Jarvis correctly
/// called it right, which is a debugging tool that lies to you.
final class CameraPreviewView: NSView {

    /// One hand as Vision saw it, already in user space.
    struct Hand {
        var joints: [CGPoint]
        /// nil when too few joints were confident to trust a position — the
        /// case worth seeing, because that hand is invisible to the recogniser
        /// even though it is plainly there on screen.
        var centre: CGPoint?
    }

    private var image: CGImage?
    private var hands: [Hand] = []
    private var note = "Camera off"

    override var isOpaque: Bool { true }

    func show(image: CGImage?, hands: [Hand], note: String) {
        self.image = image
        self.hands = hands
        self.note = note
        needsDisplay = true
    }

    func clear(note: String) {
        show(image: nil, hands: [], note: note)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor.black.setFill()
        bounds.fill()

        guard let image else {
            draw(note, at: NSPoint(x: 8, y: bounds.midY - 7), color: .secondaryLabelColor)
            return
        }

        let rect = fit(CGSize(width: image.width, height: image.height))

        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.translateBy(x: -rect.midX, y: 0)
        ctx.draw(image, in: rect)
        ctx.restoreGState()

        for hand in hands {
            // Amber for a hand Vision can see but can't place confidently
            // enough to measure — the difference between "it's not looking" and
            // "it's looking and getting nothing", which are different problems.
            let colour: NSColor = hand.centre == nil ? .systemOrange : .systemGreen
            colour.withAlphaComponent(0.9).setFill()
            for joint in hand.joints {
                let p = point(joint, in: rect)
                ctx.fillEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            }
            guard let centre = hand.centre else { continue }
            let c = point(centre, in: rect)
            colour.setStroke()
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
        }

        // The gap between two hands is the whole of the Mission Control gesture,
        // so put the number you are trying to grow on the screen.
        let centres = hands.compactMap(\.centre).sorted { $0.x < $1.x }
        if centres.count == 2 {
            let a = point(centres[0], in: rect), b = point(centres[1], in: rect)
            NSColor.systemGreen.withAlphaComponent(0.7).setStroke()
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [a, b])
            draw(String(format: "%.2f", centres[1].x - centres[0].x),
                 at: NSPoint(x: (a.x + b.x) / 2 - 12, y: (a.y + b.y) / 2 + 6),
                 color: .systemGreen)
        }

        draw(note, at: NSPoint(x: rect.minX + 6, y: rect.minY + 5), color: .white)
    }

    /// Aspect-fit, so the preview never stretches a face sideways.
    private func fit(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalized.x * rect.width,
                y: rect.minY + normalized.y * rect.height)
    }

    private func draw(_ text: String, at origin: NSPoint, color: NSColor) {
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
            .shadow: shadow,
        ]).draw(at: origin)
    }
}
