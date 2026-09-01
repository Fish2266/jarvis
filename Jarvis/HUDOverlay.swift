import AppKit

/// Puts the HUD on every screen: borderless, click-through, above everything,
/// and never steals focus from whatever you're doing.
final class HUDOverlay {

    static let shared = HUDOverlay()
    private init() {}

    private var windows: [NSWindow] = []
    private var views: [HUDView] = []
    private var tearingDown = false

    var isShowing: Bool { !windows.isEmpty }

    // MARK: - Public

    /// Claps heard — bring up the reticle and start the countdown.
    func beginListening(seconds: TimeInterval) {
        guard !isShowing else { return }
        present()
        views.forEach { $0.run(.listening(seconds: seconds)) }
    }

    /// Command resolved — burst, whether or not the HUD was already up.
    /// `headline` describes the action ("Opening Claude"), never the transcript.
    func confirm(headline: String, detail: String = "") {
        if isShowing {
            views.forEach { $0.confirm(headline: headline, detail: detail) }
        } else {
            present()
            views.forEach { $0.run(.confirmed(headline: headline, detail: detail)) }
        }
    }

    func setHeadline(_ text: String) {
        views.forEach { $0.setHeadline(text) }
    }

    /// An answer outlives the HUD. The reticle leaves on a quick schedule and
    /// the strip at the bottom of the screen keeps the text and the voice, so a
    /// slow model no longer means the answer flashes past as the HUD fades.
    func setAnswer(_ text: String) {
        AnswerBar.shared.show(text)
        views.forEach { $0.handOff() }
    }

    func setDetail(_ text: String) {
        views.forEach { $0.setDetail(text) }
    }

    func setStatus(_ text: String) {
        views.forEach { $0.setStatus(text) }
    }

    /// Escape pressed.
    func cancel() {
        guard isShowing else { return }
        views.forEach { $0.cancel() }
    }

    /// Window closed without a match — collapse quietly.
    func standDown() {
        guard isShowing else { return }
        views.forEach { $0.standDown() }
    }

    /// Menu action: run the whole sequence so you can see it without clapping.
    func preview(reply: String) {
        guard !isShowing else { return }
        beginListening(seconds: 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.isShowing else { return }
            self.confirm(headline: "Opening Claude", detail: reply)
        }
    }

    func dismissNow() {
        teardown()
    }

    // MARK: - Windows

    private func present() {
        // A new phrase supersedes whatever the last one had to say.
        AnswerBar.shared.dismiss()
        teardown()
        tearingDown = false

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                         .fullScreenAuxiliary, .ignoresCycle]

            let view = HUDView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinished = { [weak self] in self?.teardown() }
            window.contentView = view

            // orderFrontRegardless, never makeKey — the HUD must not pull focus
            // away from the app we're in the middle of launching.
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()

            windows.append(window)
            views.append(view)
        }
    }

    private func teardown() {
        guard !tearingDown else { return }
        tearingDown = true
        views.forEach { $0.onFinished = nil }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        tearingDown = false
    }
}
