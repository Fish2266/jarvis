import AppKit
import QuartzCore

/// The little countdown that sits in the corner while a timer runs.
///
/// It has to be cheap, because unlike everything else on screen it is up for
/// minutes at a time rather than seconds. So the ring is a single Core
/// Animation `strokeEnd` running the whole length of the timer — one animation
/// handed to the GPU at the start and never touched again — and the only thing
/// on a clock is the digits, which change once a second and cannot be animated
/// anyway. A twenty-minute timer costs twelve hundred label updates and no
/// per-frame work at all.
final class TimerBar {

    static let shared = TimerBar()

    private var window: NSWindow?
    private var view: TimerBarView?

    private init() {}

    var isShowing: Bool { window != nil }

    /// Shows the pill for a timer that is already running.
    func show(_ running: Countdown.Running) {
        // A replaced timer gets a fresh pill rather than a retuned one: the
        // ring's animation is set up once from the duration, and restarting it
        // in place means unwinding an animation that is already in flight.
        dismiss()
        guard let screen = Self.activeScreen() else { return }

        let size = CGSize(width: 186, height: 58)
        // Below the menu bar, inset from the right. `visibleFrame` already
        // accounts for the menu bar and the Dock wherever they are.
        let origin = CGPoint(x: screen.visibleFrame.maxX - size.width - 22,
                             y: screen.visibleFrame.maxY - size.height - 14)
        let frame = NSRect(origin: origin, size: size)

        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // One above the reticle, so a timer stays visible while a command is
        // being given. They never overlap — the reticle is centred and this is
        // in the corner — so there is nothing for it to obscure.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]

        let view = TimerBarView(frame: NSRect(origin: .zero, size: size), running: running)
        view.onFinished = { [weak self] in self?.dismiss() }
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()

        self.window = window
        self.view = view
        view.start()
    }

    /// The timer went off — flash, then leave on its own.
    func ring() {
        guard let view else { return }
        view.ring()
    }

    func dismiss() {
        view?.onFinished = nil
        view?.stop()
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    /// The screen the pointer is on, matching where the answer strip appears.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

/// The pill itself: a backdrop, a progress ring, and the digits.
final class TimerBarView: NSView {

    var onFinished: (() -> Void)?

    private let root = CALayer()
    private let backdrop = CAShapeLayer()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let label = HUD.label(size: 9, weight: .semibold)
    private let digits = HUD.label(size: 21, weight: .bold)

    private let running: Countdown.Running
    private var ticker: Timer?
    private var rang = false

    init(frame: NSRect, running: Countdown.Running) {
        self.running = running
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
        backdrop.path = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14,
                               transform: nil)
        backdrop.fillColor = CGColor(red: 0.01, green: 0.03, blue: 0.05, alpha: 0.80)
        backdrop.strokeColor = HUD.cyanFaint
        backdrop.lineWidth = 1
        root.addSublayer(backdrop)

        // The ring, on the left.
        //
        // Both ring layers get their own square coordinate space centred on
        // the circle, rather than a path drawn in the pill's coordinates. That
        // is what makes the rotation below land: a transform turns a layer
        // about its own centre, so a circle drawn off to one side of a
        // pill-shaped layer would swing across the pill instead of spinning
        // where it sits.
        let radius: CGFloat = 17
        let side = (radius + 3) * 2
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        let centre = CGPoint(x: 34, y: bounds.midY)
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: radius,
                      startAngle: 0, endAngle: .pi * 2, clockwise: false)

        for ring in [track, progress] {
            ring.bounds = box
            ring.position = centre
            ring.path = circle
            ring.fillColor = nil
            ring.lineWidth = 3
        }
        track.strokeColor = HUD.cyanFaint
        root.addSublayer(track)

        progress.strokeColor = HUD.cyan
        progress.lineCap = .round
        // Twelve o'clock, unwinding — the same direction as the reticle's
        // countdown, so the two read as the same instrument.
        progress.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
        HUD.glow(progress, color: HUD.cyan, radius: 8, opacity: 0.8)
        root.addSublayer(progress)

        label.alignmentMode = .left
        label.frame = CGRect(x: 62, y: bounds.midY + 4, width: 110, height: 12)
        label.string = HUD.text("TIMER", size: 9, weight: .semibold, color: HUD.gold, kern: 3)
        root.addSublayer(label)

        digits.alignmentMode = .left
        digits.frame = CGRect(x: 62, y: bounds.midY - 21, width: 116, height: 26)
        HUD.glow(digits, color: HUD.cyan, radius: 6, opacity: 0.6)
        root.addSublayer(digits)

        redraw()
    }

    // MARK: - Life

    func start() {
        enter()

        // The whole countdown, handed to the GPU once. Starting part-way
        // through is deliberate: a pill re-shown after being dismissed picks up
        // where the timer actually is rather than restarting the sweep.
        let remaining = running.remaining
        if remaining > 0 {
            let unwind = CABasicAnimation(keyPath: "strokeEnd")
            unwind.fromValue = 1 - running.progress
            unwind.toValue = 0
            unwind.duration = remaining
            unwind.fillMode = .forwards
            unwind.isRemovedOnCompletion = false
            progress.add(unwind, forKey: "countdown")
        } else {
            progress.strokeEnd = 0
        }

        // Once a second, and on the common mode so it keeps counting while a
        // menu is open. Digits are all this has to do; the ring draws itself.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.redraw()
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    private func redraw() {
        let remaining = running.remaining
        let colour: CGColor = rang ? HUD.gold : (remaining <= 10 ? HUD.amber : HUD.cyan)
        digits.string = HUD.text(Countdown.clock(remaining), size: 21, weight: .bold,
                                 color: colour, kern: 1)
        if !rang, remaining <= 10 {
            // The last ten seconds warm to amber, so a timer about to go off
            // looks like one out of the corner of your eye.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progress.strokeColor = HUD.amber
            progress.shadowColor = HUD.amber
            CATransaction.commit()
        }
    }

    /// Time's up.
    func ring() {
        guard !rang else { return }
        rang = true
        stop()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeEnd = 1
        progress.strokeColor = HUD.gold
        progress.shadowColor = HUD.gold
        backdrop.strokeColor = HUD.gold
        CATransaction.commit()

        label.string = HUD.text("TIME", size: 9, weight: .semibold, color: HUD.gold, kern: 3)
        digits.string = HUD.text("0:00", size: 21, weight: .bold, color: HUD.gold, kern: 1)

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1, 0.35, 1, 0.35, 1, 0.35, 1]
        pulse.keyTimes = [0, 0.16, 0.32, 0.48, 0.64, 0.8, 1]
        pulse.duration = 1.9
        root.add(pulse, forKey: "ring")

        let punch = CAKeyframeAnimation(keyPath: "transform.scale")
        punch.values = [1.0, 1.07, 1.0]
        punch.keyTimes = [0, 0.3, 1]
        punch.duration = 0.5
        punch.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(punch, forKey: "punch")

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
            self?.leave()
        }
    }

    private func enter() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        root.add(fade, forKey: "in")

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 26
        slide.toValue = 0
        slide.duration = 0.42
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(slide, forKey: "slide")
    }

    private func leave() {
        stop()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.38
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        root.add(fade, forKey: "out")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.onFinished?()
        }
    }
}
