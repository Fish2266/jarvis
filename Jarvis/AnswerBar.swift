import AppKit
import QuartzCore

/// The line that stays behind after the reticle has gone.
///
/// An answer used to hold the whole HUD open for as long as it took to read,
/// which is too much screen to give a sentence — and when the model was slow the
/// answer arrived just as the HUD was already fading, so it flashed past. This
/// is the other half of that trade: the reticle keeps its quick exit, and the
/// text moves down here to a strip that lingers on its own with the voice drawn
/// underneath it. Readable with the sound off, small enough to work over.
enum Readout {

    // MARK: - Layout

    static let padX: CGFloat = 28
    static let padTop: CGFloat = 16
    static let padBottom: CGFloat = 16
    static let labelHeight: CGFloat = 12
    static let waveHeight: CGFloat = 30
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 3

    /// Smaller type as answers get longer, so a paragraph still fits a strip.
    static func fontSize(for text: String) -> CGFloat {
        text.count > 180 ? 14 : (text.count > 90 ? 16 : 18)
    }

    static func barWidthTotal() -> CGFloat { barWidth + barGap }

    static func width(forScreen screenWidth: CGFloat) -> CGFloat {
        max(420, min(860, screenWidth * 0.60))
    }

    static func barCount(forWidth width: CGFloat) -> Int {
        max(8, Int((width - padX * 2) / barWidthTotal()))
    }

    /// How long the strip stays up with the sound off — roughly reading pace,
    /// with a floor so a two-word answer doesn't blink out before you look at it.
    static func readingTime(_ text: String) -> TimeInterval {
        let words = Double(text.split(separator: " ").filter { !$0.isEmpty }.count)
        return min(max(words * 0.36 + 2.4, 3.4), 16)
    }

    static func paragraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = 3
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
            .kern: 0.4,
            .paragraphStyle: paragraph(),
        ])
    }

    /// Measured, not guessed: the strip is only as tall as the sentence needs.
    static func textHeight(_ text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let bounds = attributed(text, size: size).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    static func size(for text: String, screenWidth: CGFloat) -> CGSize {
        let width = width(forScreen: screenWidth)
        let size = fontSize(for: text)
        let height = padTop + 1 + 6 + labelHeight + 10
            + textHeight(text, size: size, width: width - padX * 2)
            + 14 + waveHeight + padBottom
        return CGSize(width: width, height: ceil(height))
    }

    // MARK: - Waveform

    /// Bar heights for one frame, newest sample at the right.
    ///
    /// Tapered towards both ends so the trace fades into the rail instead of
    /// stopping dead, and zero wherever the playhead hasn't reached yet — which
    /// is what makes it read as the voice arriving rather than a loop.
    static func levels(envelope: [Float], playhead: Int, bars: Int, stride: Int = 1) -> [Float] {
        guard bars > 0 else { return [] }
        let step = max(1, stride)
        return (0..<bars).map { i in
            let index = playhead - (bars - 1 - i) * step
            let value = (index >= 0 && index < envelope.count) ? envelope[index] : 0
            return value * taper(i, of: bars)
        }
    }

    /// A slow travelling swell for when there's nothing to draw — no audio yet,
    /// speech turned off, or the line finished but the text still up. Alive
    /// enough to look like a standby trace, never loud enough to read as speech.
    static func idleLevels(bars: Int, time: Double) -> [Float] {
        guard bars > 0 else { return [] }
        return (0..<bars).map { i in
            let position = (Float(i) + 0.5) / Float(bars)
            let swell = (sin(Float(time) * 2.0 - position * 13.0) + 1) / 2
            // Only a light taper here. The full one varies three-fold across the
            // strip, which swamps the travelling crest and leaves a static bulge.
            let edge = 0.72 + 0.28 * sin(Float.pi * position)
            return (0.05 + 0.23 * swell) * edge
        }
    }

    /// Cyan through to gold, so the loud parts of a line pick up the same colour
    /// the reticle turns when a command lands. Precomputed: picking a colour per
    /// bar per frame would mean thousands of allocations a second for nothing.
    static let barColors: [CGColor] = (0..<12).map { step in
        let t = CGFloat(step) / 11
        let warm = max(0, (t - 0.55) / 0.45)
        return CGColor(red: 0.35 + 0.65 * warm,
                       green: 0.91 - 0.13 * warm,
                       blue: 1.00 - 0.68 * warm,
                       alpha: 1)
    }

    static func barColor(for level: Float) -> CGColor {
        barColors[colorIndex(for: level)]
    }

    /// Which step of the ramp a level lands on. Exposed so the draw loop can
    /// notice the colour hasn't moved and skip the assignment.
    static func colorIndex(for level: Float) -> Int {
        Int((max(0, min(1, level)) * Float(barColors.count - 1)).rounded())
    }

    private static func taper(_ i: Int, of bars: Int) -> Float {
        let position = (Float(i) + 0.5) / Float(bars)
        return 0.35 + 0.65 * sin(Float.pi * position)
    }
}

/// Owns the strip's window. One screen only — the one you're pointing at.
final class AnswerBar {

    static let shared = AnswerBar()

    private var window: NSWindow?
    private var view: AnswerBarView?

    private init() {
        // Set up once, here rather than at a call site, so a spoken line always
        // finds the strip if one happens to be up and is ignored if not.
        VoiceBox.shared.onPlayback = { [weak self] envelope, duration in
            self?.view?.attachVoice(envelope: envelope, duration: duration)
        }
    }

    var isShowing: Bool { window != nil }

    func show(_ text: String) {
        dismiss()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let screen = Self.activeScreen() else { return }
        let size = Readout.size(for: text, screenWidth: screen.frame.width)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.minY + 120)
        let frame = NSRect(origin: origin, size: size)

        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]

        let view = AnswerBarView(frame: NSRect(origin: .zero, size: size), text: text)
        view.onFinished = { [weak self] in self?.dismiss() }
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()

        self.window = window
        self.view = view
        view.start()
    }

    /// Escape, or a new phrase starting — go now, no exit animation.
    func dismiss() {
        view?.onFinished = nil
        view?.stop()
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    /// The screen the pointer is on. nil when there is no screen at all —
    /// every display asleep or disconnected — which `screens[0]` used to turn
    /// into a crash rather than a strip that simply doesn't appear.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

/// The strip itself: backdrop, rail, text, and a waveform driven by the audio
/// that's actually playing rather than a canned animation.
final class AnswerBarView: NSView {

    var onFinished: (() -> Void)?

    private let root = CALayer()
    private let backdrop = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let rail = CALayer()
    private let railTicks = CAShapeLayer()
    private let corners = CAShapeLayer()
    private let label = HUD.label(size: 10, weight: .semibold)
    private let body = HUD.label(size: 18, weight: .medium)
    private let wave = CALayer()
    private var bars: [CALayer] = []
    /// Last colour step written to each bar. The ramp only has twelve steps, so
    /// most frames leave most bars alone — worth tracking across roughly a
    /// hundred bars redrawn sixty times a second.
    private var barColorSteps: [Int] = []

    private let text: String
    private var envelope: [Float] = []
    private var voiceStart: CFTimeInterval?
    private var voiceDuration: TimeInterval = 0
    private var shown: [Float] = []
    private var began: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var ticker: Timer?
    private var leaving = false

    init(frame: NSRect, text: String) {
        self.text = text
        super.init(frame: frame)
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

    // MARK: - Building

    private func build() {
        let inner = bounds.insetBy(dx: Readout.padX, dy: 0)

        // Enough backing to stay legible over a bright desktop, not so much that
        // it reads as a window.
        backdrop.path = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16,
                               transform: nil)
        backdrop.fillColor = CGColor(red: 0.01, green: 0.03, blue: 0.05, alpha: 0.78)
        backdrop.strokeColor = HUD.cyanFaint
        backdrop.lineWidth = 1
        root.addSublayer(backdrop)

        sheen.frame = bounds
        sheen.colors = [
            CGColor(red: 0.35, green: 0.91, blue: 1.00, alpha: 0.10),
            CGColor(red: 0.35, green: 0.91, blue: 1.00, alpha: 0.00),
        ]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.35)
        sheen.mask = {
            let mask = CAShapeLayer()
            mask.path = backdrop.path
            mask.fillColor = HUD.white
            return mask
        }()
        root.addSublayer(sheen)

        let railY = bounds.height - Readout.padTop
        rail.frame = CGRect(x: inner.minX, y: railY, width: inner.width, height: 1)
        rail.backgroundColor = HUD.gold
        HUD.glow(rail, color: HUD.gold, radius: 4, opacity: 0.8)
        root.addSublayer(rail)

        // End ticks and corner brackets — the furniture that makes it read as an
        // instrument rather than a notification.
        let ticks = CGMutablePath()
        for x in [inner.minX, inner.maxX - 1] {
            ticks.addRect(CGRect(x: x, y: railY - 4, width: 1, height: 9))
        }
        railTicks.path = ticks
        railTicks.fillColor = HUD.gold
        root.addSublayer(railTicks)

        let bracket = CGMutablePath()
        let arm: CGFloat = 13
        let inset: CGFloat = 7
        for (cx, cy, sx, sy) in [(inset, inset, 1.0, 1.0),
                                 (bounds.width - inset, inset, -1.0, 1.0),
                                 (inset, bounds.height - inset, 1.0, -1.0),
                                 (bounds.width - inset, bounds.height - inset, -1.0, -1.0)] {
            bracket.move(to: CGPoint(x: cx + arm * CGFloat(sx), y: cy))
            bracket.addLine(to: CGPoint(x: cx, y: cy))
            bracket.addLine(to: CGPoint(x: cx, y: cy + arm * CGFloat(sy)))
        }
        corners.path = bracket
        corners.strokeColor = HUD.cyanMid
        corners.fillColor = nil
        corners.lineWidth = 1.5
        root.addSublayer(corners)

        label.alignmentMode = .left
        label.frame = CGRect(x: inner.minX, y: railY - 6 - Readout.labelHeight,
                             width: inner.width, height: Readout.labelHeight)
        label.string = HUD.text("RESPONSE", size: 10, weight: .semibold,
                                color: HUD.gold, kern: 3)
        root.addSublayer(label)

        let size = Readout.fontSize(for: text)
        let height = Readout.textHeight(text, size: size, width: inner.width)
        body.isWrapped = true
        body.alignmentMode = .center
        body.frame = CGRect(x: inner.minX, y: label.frame.minY - 10 - height,
                            width: inner.width, height: height)
        body.string = Readout.attributed(text, size: size)
        HUD.glow(body, color: HUD.gold, radius: 7, opacity: 0.5)
        root.addSublayer(body)

        wave.frame = CGRect(x: inner.minX, y: Readout.padBottom,
                            width: inner.width, height: Readout.waveHeight)
        HUD.glow(wave, color: HUD.cyan, radius: 6, opacity: 0.85)
        root.addSublayer(wave)

        let count = Readout.barCount(forWidth: bounds.width)
        shown = [Float](repeating: 0, count: count)
        barColorSteps = [Int](repeating: -1, count: count)
        let span = Readout.barWidthTotal()
        let offset = (inner.width - (span * CGFloat(count) - Readout.barGap)) / 2
        let midY = Readout.waveHeight / 2
        for i in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = HUD.cyan
            bar.cornerRadius = Readout.barWidth / 2
            bar.frame = CGRect(x: offset + CGFloat(i) * span, y: midY - 1,
                               width: Readout.barWidth, height: 2)
            wave.addSublayer(bar)
            bars.append(bar)
        }
    }

    // MARK: - Life

    func start() {
        began = CACurrentMediaTime()
        deadline = began + Readout.readingTime(text)
        enter()
        // 60 Hz on the common mode so it keeps drawing while menus are open.
        let ticker = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    /// The voice is playing — draw it, and stay up until it has finished talking.
    func attachVoice(envelope: [Float], duration: TimeInterval) {
        guard !leaving else { return }
        self.envelope = envelope
        self.voiceDuration = duration
        self.voiceStart = CACurrentMediaTime()
        deadline = max(deadline, CACurrentMediaTime() + duration + 1.2)
    }

    private func enter() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        root.add(fade, forKey: "in")

        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -14
        rise.toValue = 0
        rise.duration = 0.42
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(rise, forKey: "rise")

        // The rail draws itself out from the centre — the one flourish worth
        // paying for, because it's what the eye follows down from the reticle.
        let open = CABasicAnimation(keyPath: "transform.scale.x")
        open.fromValue = 0.02
        open.toValue = 1
        open.duration = 0.5
        open.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rail.add(open, forKey: "open")
        railTicks.add(fadeIn(after: 0.34), forKey: "in")
        corners.add(fadeIn(after: 0.22), forKey: "in")
        label.add(fadeIn(after: 0.18), forKey: "in")
        body.add(fadeIn(after: 0.24), forKey: "in")
    }

    private func fadeIn(after delay: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        return fade
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if !leaving, now >= deadline {
            leave()
            return
        }

        var speaking = false
        var target: [Float]
        if let start = voiceStart, !envelope.isEmpty, now - start <= voiceDuration + 0.25 {
            let playhead = Int((now - start) * VoiceBox.envelopeHz)
            target = Readout.levels(envelope: envelope, playhead: playhead, bars: shown.count)
            speaking = true
        } else {
            target = Readout.idleLevels(bars: shown.count, time: now - began)
        }
        if leaving { target = target.map { _ in 0 }; speaking = false }

        for i in 0..<shown.count {
            if speaking {
                // Fast attack, slow release, so the bars snap up with the voice
                // and settle back rather than strobing between frames.
                shown[i] = max(target[i], shown[i] * 0.80)
            } else {
                // The standby wave is already smooth, and holding its peaks would
                // smear the travelling crest into one flat bulge — follow it.
                shown[i] += (target[i] - shown[i]) * 0.35
            }
        }
        draw()
    }

    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = Readout.waveHeight / 2
        let reach = Readout.waveHeight / 2 - 1
        for (i, bar) in bars.enumerated() {
            let half = 1 + CGFloat(shown[i]) * reach
            var frame = bar.frame
            frame.origin.y = midY - half
            frame.size.height = half * 2
            bar.frame = frame
            let step = Readout.colorIndex(for: shown[i])
            if barColorSteps[i] != step {
                barColorSteps[i] = step
                bar.backgroundColor = Readout.barColors[step]
            }
            bar.opacity = Float(0.55 + min(0.45, Double(shown[i]) * 0.9))
        }
        CATransaction.commit()
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true

        let close = CABasicAnimation(keyPath: "transform.scale.x")
        close.fromValue = 1
        close.toValue = 0.02
        close.duration = 0.34
        close.timingFunction = CAMediaTimingFunction(name: .easeIn)
        close.fillMode = .forwards
        close.isRemovedOnCompletion = false
        rail.add(close, forKey: "close")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.42
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "out")

        let sink = CABasicAnimation(keyPath: "transform.translation.y")
        sink.fromValue = 0
        sink.toValue = -10
        sink.duration = 0.42
        sink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        sink.fillMode = .forwards
        sink.isRemovedOnCompletion = false
        root.add(sink, forKey: "sink")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) { [weak self] in
            self?.onFinished?()
        }
    }
}
