import AppKit
import QuartzCore

/// The heads-up display itself: a layer tree that scales in, spins, and either
/// bursts on a confirmed phrase or quietly collapses on a miss.
///
/// Everything animates through Core Animation rather than per-frame drawing, so
/// the whole thing runs on the GPU and costs nothing while it's idle.
final class HUDView: NSView {

    enum Phase {
        case listening(seconds: TimeInterval)
        case confirmed(headline: String, detail: String)
        case standDown
    }

    var onFinished: (() -> Void)?

    private let root = CALayer()
    private let tint = CALayer()
    private let haze = CAGradientLayer()
    private let reticle = CALayer()
    private let sweep = CALayer()
    private let flash = CALayer()
    private let emitter = CAEmitterLayer()
    private let scanline = CALayer()

    private var accentRings: [CAShapeLayer] = []
    private var countdown = CAShapeLayer()
    private var brackets: [CAShapeLayer] = []
    private var readouts: [CATextLayer] = []

    private let brand = HUD.label(size: 13, weight: .semibold)
    private let status = HUD.label(size: 15, weight: .medium)
    private let headline = HUD.label(size: 34, weight: .bold)
    private let detail = HUD.label(size: 15, weight: .regular)

    private var diameter: CGFloat = 520
    private var dismissWork: DispatchWorkItem?

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = root
        wantsLayer = true
        root.backgroundColor = .clear
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor { HUD.applyScale(scale, to: root) }
    }

    private var mid: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func build() {
        // Leave room above for the brand mark and below for the three text lines.
        diameter = max(min(min(bounds.width * 0.46, bounds.height - 430), 600), 320)
        let r = diameter / 2

        // Screen darkening: a flat tint plus a pool of shadow behind the reticle,
        // so the cyan reads against a bright desktop.
        tint.frame = bounds
        tint.backgroundColor = CGColor(red: 0, green: 0.02, blue: 0.05, alpha: 0.58)
        root.addSublayer(tint)

        haze.frame = bounds
        haze.type = .radial
        haze.colors = [
            CGColor(red: 0, green: 0.04, blue: 0.09, alpha: 0.62),
            CGColor(red: 0, green: 0.03, blue: 0.08, alpha: 0.0),
        ]
        haze.locations = [0, 1]
        haze.startPoint = CGPoint(x: 0.5, y: 0.5)
        haze.endPoint = CGPoint(x: 1.1, y: 1.1)
        root.addSublayer(haze)

        buildBrackets()
        buildReadouts()

        // Reticle -------------------------------------------------------------
        reticle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        reticle.position = mid
        root.addSublayer(reticle)

        let outer = ring(radius: r * 0.98, width: 1, color: HUD.cyanSoft,
                         dash: [2, 10])
        spin(outer, seconds: 26, clockwise: true)

        let ticks = tickRing(inner: r * 0.80, outer: r * 0.88, count: 84, every: 7,
                             extra: r * 0.05, color: HUD.cyanSoft, width: 1.4)
        spin(ticks, seconds: 34, clockwise: false)

        let segs = arcRing(radius: r * 0.72, width: 4, color: HUD.cyan,
                           spans: [(0, 74), (120, 52), (196, 88), (306, 30)])
        HUD.glow(segs, color: HUD.cyan, radius: 12)
        spin(segs, seconds: 9, clockwise: true)
        accentRings.append(segs)

        let inner = arcRing(radius: r * 0.44, width: 1.5, color: HUD.cyanSoft,
                            spans: [(20, 130), (200, 130)])
        spin(inner, seconds: 14, clockwise: false)
        accentRings.append(inner)

        // The countdown: a full circle that unwinds over the listening window.
        countdown = ring(radius: r * 0.58, width: 4, color: HUD.cyan, dash: nil)
        countdown.strokeEnd = 1
        countdown.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)  // start at 12 o'clock
        HUD.glow(countdown, color: HUD.cyan, radius: 13)

        reticle.addSublayer(crosshair(r: r))
        reticle.addSublayer(coreDot(r: r))

        // Sweep ---------------------------------------------------------------
        sweep.bounds = reticle.bounds
        sweep.position = CGPoint(x: r, y: r)
        buildSweep(radius: r * 0.56)
        reticle.addSublayer(sweep)
        spin(sweep, seconds: 2.6, clockwise: true)

        // Particles -----------------------------------------------------------
        emitter.frame = bounds
        emitter.emitterPosition = mid
        emitter.emitterShape = .circle
        emitter.emitterMode = .outline
        emitter.emitterSize = CGSize(width: diameter * 0.62, height: diameter * 0.62)
        emitter.birthRate = 0
        if let sprite = HUD.particleImage() {
            let cell = CAEmitterCell()
            cell.contents = sprite
            cell.birthRate = 900
            cell.lifetime = 1.3
            cell.velocity = 300
            cell.velocityRange = 170
            cell.emissionRange = .pi * 2
            cell.scale = 0.30
            cell.scaleRange = 0.22
            cell.scaleSpeed = -0.16
            cell.alphaSpeed = -0.85
            cell.color = HUD.cyan
            emitter.emitterCells = [cell]
        }
        root.addSublayer(emitter)

        // Text ----------------------------------------------------------------
        brand.frame = CGRect(x: 0, y: mid.y + diameter / 2 + 34, width: bounds.width, height: 20)
        brand.string = HUD.text("J A R V I S", size: 13, weight: .semibold, color: HUD.cyanMid, kern: 8)
        root.addSublayer(brand)

        let below = mid.y - diameter / 2

        status.frame = CGRect(x: 0, y: below - 56, width: bounds.width, height: 24)
        HUD.glow(status, color: HUD.cyan, radius: 9, opacity: 0.8)
        root.addSublayer(status)

        headline.frame = CGRect(x: 0, y: below - 116, width: bounds.width, height: 48)
        HUD.glow(headline, color: HUD.cyan, radius: 16, opacity: 0.85)
        root.addSublayer(headline)

        detail.frame = CGRect(x: 0, y: below - 154, width: bounds.width, height: 24)
        root.addSublayer(detail)

        // Full-screen flash for the confirmation hit.
        flash.frame = bounds
        flash.backgroundColor = HUD.cyan
        flash.opacity = 0
        root.addSublayer(flash)

        scanline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 2)
        scanline.backgroundColor = HUD.cyanSoft
        scanline.opacity = 0
        HUD.glow(scanline, color: HUD.cyan, radius: 8)
        root.addSublayer(scanline)

        reticle.addSublayer(countdown)
    }

    // MARK: - Geometry

    private func centeredPath() -> (CGPoint, CGMutablePath) {
        (CGPoint(x: diameter / 2, y: diameter / 2), CGMutablePath())
    }

    private func shape(_ path: CGPath, width: CGFloat, color: CGColor,
                       fill: CGColor? = nil) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = reticle.bounds
        layer.path = path
        layer.lineWidth = width
        layer.strokeColor = color
        layer.fillColor = fill
        layer.lineCap = .round
        reticle.addSublayer(layer)
        return layer
    }

    private func ring(radius: CGFloat, width: CGFloat, color: CGColor,
                      dash: [NSNumber]?) -> CAShapeLayer {
        let (c, path) = centeredPath()
        path.addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        let layer = shape(path, width: width, color: color)
        layer.lineDashPattern = dash
        return layer
    }

    private func tickRing(inner: CGFloat, outer: CGFloat, count: Int, every: Int,
                          extra: CGFloat, color: CGColor, width: CGFloat) -> CAShapeLayer {
        let (c, path) = centeredPath()
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * .pi * 2
            let long = i % every == 0
            let r1 = inner - (long ? extra : 0)
            let r2 = outer
            path.move(to: CGPoint(x: c.x + cos(angle) * r1, y: c.y + sin(angle) * r1))
            path.addLine(to: CGPoint(x: c.x + cos(angle) * r2, y: c.y + sin(angle) * r2))
        }
        return shape(path, width: width, color: color)
    }

    /// `spans` are (startDegrees, sweepDegrees) pairs.
    private func arcRing(radius: CGFloat, width: CGFloat, color: CGColor,
                         spans: [(CGFloat, CGFloat)]) -> CAShapeLayer {
        let (c, path) = centeredPath()
        for (start, sweep) in spans {
            let a0 = start * .pi / 180
            let a1 = (start + sweep) * .pi / 180
            // Start a fresh subpath at the arc's own start point, otherwise
            // addArc draws a connecting line from wherever the pen was.
            path.move(to: CGPoint(x: c.x + cos(a0) * radius, y: c.y + sin(a0) * radius))
            path.addArc(center: c, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        }
        return shape(path, width: width, color: color)
    }

    private func crosshair(r: CGFloat) -> CAShapeLayer {
        let (c, path) = centeredPath()
        for i in 0..<4 {
            let angle = CGFloat(i) * .pi / 2
            path.move(to: CGPoint(x: c.x + cos(angle) * r * 0.20, y: c.y + sin(angle) * r * 0.20))
            path.addLine(to: CGPoint(x: c.x + cos(angle) * r * 0.31, y: c.y + sin(angle) * r * 0.31))
        }
        let layer = CAShapeLayer()
        layer.frame = reticle.bounds
        layer.path = path
        layer.lineWidth = 1.5
        layer.strokeColor = HUD.cyanSoft
        layer.fillColor = nil
        return layer
    }

    private func coreDot(r: CGFloat) -> CAShapeLayer {
        let (c, path) = centeredPath()
        path.addArc(center: c, radius: r * 0.115, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        let layer = CAShapeLayer()
        layer.frame = reticle.bounds
        layer.path = path
        layer.fillColor = CGColor(red: 0.35, green: 0.91, blue: 1.0, alpha: 0.10)
        layer.strokeColor = HUD.cyan
        layer.lineWidth = 1
        HUD.glow(layer, color: HUD.cyan, radius: 12, opacity: 0.6)
        return layer
    }

    /// A comet tail built from wedges of decreasing opacity — cheaper than a
    /// conic gradient and it reads better at small sizes.
    private func buildSweep(radius: CGFloat) {
        let count = 64
        let step: CGFloat = 1.8
        for i in 0..<count {
            let path = CGMutablePath()
            let c = CGPoint(x: diameter / 2, y: diameter / 2)
            let a1 = -CGFloat(i) * step * .pi / 180
            let a2 = -CGFloat(i + 1) * step * .pi / 180
            path.move(to: c)
            path.addArc(center: c, radius: radius, startAngle: a1, endAngle: a2, clockwise: true)
            path.closeSubpath()

            let wedge = CAShapeLayer()
            wedge.frame = reticle.bounds
            wedge.path = path
            let t = Double(i) / Double(count)
            wedge.fillColor = CGColor(red: 0.35, green: 0.91, blue: 1.0,
                                      alpha: 0.50 * pow(1 - t, 2.0))
            wedge.strokeColor = nil
            sweep.addSublayer(wedge)
        }

        // Bright leading edge, so the sweep reads as a radar hand rather than a pie slice.
        let edge = CGMutablePath()
        let c = CGPoint(x: diameter / 2, y: diameter / 2)
        edge.move(to: c)
        edge.addLine(to: CGPoint(x: c.x + radius, y: c.y))
        let edgeLayer = CAShapeLayer()
        edgeLayer.frame = reticle.bounds
        edgeLayer.path = edge
        edgeLayer.lineWidth = 2
        edgeLayer.strokeColor = HUD.cyan
        edgeLayer.fillColor = nil
        HUD.glow(edgeLayer, color: HUD.cyan, radius: 10, opacity: 0.8)
        sweep.addSublayer(edgeLayer)
    }

    private func buildBrackets() {
        let inset: CGFloat = 54
        let leg: CGFloat = 110
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: inset, y: inset), 1, 1),
            (CGPoint(x: bounds.width - inset, y: inset), -1, 1),
            (CGPoint(x: inset, y: bounds.height - inset), 1, -1),
            (CGPoint(x: bounds.width - inset, y: bounds.height - inset), -1, -1),
        ]
        for (origin, sx, sy) in corners {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: origin.x + sx * leg, y: origin.y))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + sy * leg))

            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.path = path
            layer.lineWidth = 2
            layer.strokeColor = HUD.cyan
            layer.fillColor = nil
            layer.lineCap = .square
            HUD.glow(layer, color: HUD.cyan, radius: 8, opacity: 0.7)
            root.addSublayer(layer)
            brackets.append(layer)
        }
    }

    private func buildReadouts() {
        let lines = [
            ("MK VII", CGPoint(x: 74, y: bounds.height - 92), CATextLayerAlignmentMode.left),
            ("SIG LOCK", CGPoint(x: bounds.width - 274, y: bounds.height - 92), .right),
            ("AUD 48.0 kHz", CGPoint(x: 74, y: 74), .left),
            ("LNK ●  SYS 100%", CGPoint(x: bounds.width - 274, y: 74), .right),
        ]
        for (text, origin, alignment) in lines {
            let layer = HUD.label(size: 11, weight: .medium)
            layer.alignmentMode = alignment
            layer.frame = CGRect(origin: origin, size: CGSize(width: 200, height: 16))
            layer.string = HUD.text(text, size: 11, weight: .medium, color: HUD.cyanMid, kern: 3)
            root.addSublayer(layer)
            readouts.append(layer)
        }
    }

    // MARK: - Animation helpers

    private func spin(_ layer: CALayer, seconds: Double, clockwise: Bool) {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = (clockwise ? -1 : 1) * Double.pi * 2
        animation.duration = seconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "spin")
    }

    /// Opacity stutter — reads like a signal locking on.
    private func flicker(_ layer: CALayer, delay: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0.8, 0.15, 1.0, 0.4, 1.0]
        animation.keyTimes = [0, 0.15, 0.3, 0.5, 0.65, 1]
        animation.duration = 0.42
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        layer.opacity = 1
        layer.add(animation, forKey: "flicker")
    }

    private func setText(_ layer: CATextLayer, _ string: String, size: CGFloat,
                         weight: NSFont.Weight, color: CGColor, kern: CGFloat) {
        layer.string = HUD.text(string, size: size, weight: weight, color: color, kern: kern)
    }

    // MARK: - Phases

    func run(_ phase: Phase) {
        switch phase {
        case .listening(let seconds):
            enter()
            setText(status, "AWAITING VOICE AUTHORIZATION", size: 15,
                    weight: .medium, color: HUD.cyan, kern: 2.5)
            flicker(status, delay: 0.20)

            countdown.strokeEnd = 1
            let unwind = CABasicAnimation(keyPath: "strokeEnd")
            unwind.fromValue = 1
            unwind.toValue = 0
            unwind.duration = seconds
            unwind.fillMode = .forwards
            unwind.isRemovedOnCompletion = false
            countdown.add(unwind, forKey: "countdown")

        case .confirmed(let headline, let detail):
            enter()
            confirm(headline: headline, detail: detail)

        case .standDown:
            standDown()
        }
    }

    /// Called when a command resolves while the HUD is already up.
    /// `headline` is what Jarvis is *doing* — never the raw transcript.
    func confirm(headline text: String, detail detailText: String) {
        dismissWork?.cancel()
        countdown.removeAnimation(forKey: "countdown")

        // Snap the countdown ring closed and turn the accents gold.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        countdown.strokeEnd = 1
        countdown.strokeColor = HUD.gold
        countdown.shadowColor = HUD.gold
        for ring in accentRings {
            ring.strokeColor = HUD.gold
            ring.shadowColor = HUD.gold
        }
        for bracket in brackets {
            bracket.strokeColor = HUD.gold
            bracket.shadowColor = HUD.gold
        }
        CATransaction.commit()

        // Impact flash.
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 0.42, 0]
        pulse.keyTimes = [0, 0.12, 1]
        pulse.duration = 0.42
        flash.add(pulse, forKey: "flash")

        // Shockwave.
        let punch = CAKeyframeAnimation(keyPath: "transform.scale")
        punch.values = [1.0, 1.10, 0.99, 1.0]
        punch.keyTimes = [0, 0.25, 0.6, 1]
        punch.duration = 0.6
        punch.timingFunction = CAMediaTimingFunction(name: .easeOut)
        reticle.add(punch, forKey: "punch")

        emitterBurst()
        sweepScanline()

        setText(status, "ACCESS GRANTED", size: 15, weight: .bold, color: HUD.gold, kern: 5)
        status.shadowColor = HUD.gold
        flicker(status, delay: 0)

        setText(headline, text.uppercased(), size: 34, weight: .bold, color: HUD.white, kern: 4)
        headline.shadowColor = HUD.gold
        flicker(headline, delay: 0.12)

        if !detailText.isEmpty { setDetail(detailText, animated: true) }

        // Long enough that an async result (a spoken reply, a weather lookup)
        // lands while the HUD is still up.
        scheduleDismiss(after: 2.6, duration: 0.55, expand: true)
    }

    /// Swap the headline after the fact — used when a result arrives, e.g. the
    /// weather replacing "Checking the weather".
    func setHeadline(_ text: String) {
        setText(headline, text.uppercased(), size: 34, weight: .bold, color: HUD.white, kern: 4)
        flicker(headline, delay: 0)
    }

    /// An answer arrived — get out of its way.
    ///
    /// The reticle used to hold itself open for the whole answer, up to fifteen
    /// seconds of full-screen furniture for one sentence. The text now lives in
    /// the strip at the bottom (see `Readout`), which lingers on its own, so all
    /// this has to do is leave promptly. Deliberately faster than the usual exit:
    /// the two animations overlap, and the reticle collapsing is what draws the
    /// eye down to the strip coming up.
    func handOff() {
        dismissWork?.cancel()
        countdown.removeAnimation(forKey: "countdown")
        setStatus("ANSWER", color: HUD.gold)
        scheduleDismiss(after: 0.12, duration: 0.45, expand: true)
    }

    func setDetail(_ text: String, animated: Bool = true) {
        setText(detail, text, size: 15, weight: .regular, color: HUD.cyanMid, kern: 1)
        if animated { flicker(detail, delay: 0) } else { detail.opacity = 1 }
    }

    func setStatus(_ text: String, color: CGColor = HUD.cyan) {
        setText(status, text, size: 15, weight: .medium, color: color, kern: 3)
        status.shadowColor = color
        flicker(status, delay: 0)
    }

    /// Escape was pressed — get off the screen immediately.
    func cancel() {
        dismissWork?.cancel()
        countdown.removeAnimation(forKey: "countdown")
        setText(status, "CANCELLED", size: 15, weight: .medium, color: HUD.amber, kern: 4)
        status.shadowColor = HUD.amber
        setText(headline, "", size: 34, weight: .bold, color: HUD.white, kern: 4)
        setText(detail, "", size: 15, weight: .regular, color: HUD.cyanMid, kern: 1)
        scheduleDismiss(after: 0.12, duration: 0.28, expand: false)
    }

    func standDown() {
        dismissWork?.cancel()
        countdown.removeAnimation(forKey: "countdown")
        setText(status, "STANDING DOWN", size: 15, weight: .medium, color: HUD.amber, kern: 4)
        status.shadowColor = HUD.amber
        flicker(status, delay: 0)
        scheduleDismiss(after: 0.5, duration: 0.4, expand: false)
    }

    // MARK: - Entrance / exit

    private func enter() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.26
        root.add(fade, forKey: "in")

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.82, 1.04, 1.0]
        pop.keyTimes = [0, 0.65, 1]
        pop.duration = 0.5
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        reticle.add(pop, forKey: "pop")

        for (i, bracket) in brackets.enumerated() {
            let slide = CABasicAnimation(keyPath: "opacity")
            slide.fromValue = 0
            slide.toValue = 1
            slide.duration = 0.3
            slide.beginTime = CACurrentMediaTime() + 0.05 * Double(i)
            slide.fillMode = .backwards
            bracket.add(slide, forKey: "in")
        }
        for (i, readout) in readouts.enumerated() {
            flicker(readout, delay: 0.15 + 0.06 * Double(i))
        }
        flicker(brand, delay: 0.1)
    }

    private func emitterBurst() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 1
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.emitter.birthRate = 0
            CATransaction.commit()
        }
    }

    private func sweepScanline() {
        scanline.opacity = 1
        let travel = CABasicAnimation(keyPath: "position.y")
        travel.fromValue = bounds.height
        travel.toValue = 0
        travel.duration = 0.7
        travel.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        fade.duration = 0.7

        let group = CAAnimationGroup()
        group.animations = [travel, fade]
        group.duration = 0.7
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        scanline.add(group, forKey: "scan")
    }

    private func scheduleDismiss(after delay: TimeInterval, duration: TimeInterval, expand: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            self.root.add(fade, forKey: "out")

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = expand ? 1.18 : 0.9
            scale.duration = duration
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            self.reticle.add(scale, forKey: "out")

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.onFinished?()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
