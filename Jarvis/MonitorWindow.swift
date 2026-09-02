import AppKit

/// Live view of what the detector is hearing. Useful for picking a sensitivity:
/// clap and watch whether the peak clears the threshold line.
final class MonitorWindow: NSWindowController, NSWindowDelegate {

    /// Fires as the window appears and disappears, so the engine can stop
    /// reporting levels to a window that isn't there.
    var onVisibilityChange: ((Bool) -> Void)?

    private let meter = NSLevelIndicator()
    private let numbers = NSTextField(labelWithString: "")
    private let transcript = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private var peakHold: Float = 0
    private var peakDecayTimer: Timer?
    private var logLines = 0

    /// Long enough to scroll back through a session, bounded so a Mac left
    /// running for days doesn't accumulate the whole log in memory.
    private static let maxLogLines = 500

    /// One formatter for the window's life. Building one per line is most of
    /// the cost of logging.
    private static let stamper: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// The engine keeps reporting levels whether or not anyone is looking, and
    /// this controller is kept alive once opened — so every UI update here is
    /// gated on the window actually being on screen.
    private var isVisible: Bool { window?.isVisible ?? false }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Jarvis — Clap Monitor"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
        // The meter used to keep ticking twenty times a second for the rest of
        // the session, drawing into a window nobody could see.
        peakDecayTimer?.invalidate()
        peakDecayTimer = nil
    }

    private func startMeter() {
        guard peakDecayTimer == nil else { return }
        peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            guard let self, self.isVisible else { return }
            self.peakHold *= 0.86
            self.meter.floatValue = min(1, self.peakHold * 4)
        }
    }

    /// The log keeps recording while the window is closed but doesn't scroll,
    /// so catch up on the way back in.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        onVisibilityChange?(true)
        startMeter()
        logView.scrollToEndOfDocument(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0
        meter.maxValue = 1
        meter.warningValue = 0.6
        meter.criticalValue = 0.85
        meter.translatesAutoresizingMaskIntoConstraints = false

        numbers.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        numbers.stringValue = "level —   background —   threshold —"
        numbers.translatesAutoresizingMaskIntoConstraints = false

        transcript.font = .systemFont(ofSize: 12, weight: .medium)
        transcript.textColor = .secondaryLabelColor
        transcript.lineBreakMode = .byTruncatingTail
        transcript.stringValue = "…"
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        scroll.documentView = logView

        let hint = NSTextField(labelWithString:
            "Clap twice. Each clap should spike well past the threshold; if the log says a sound was ignored, raise sensitivity.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.translatesAutoresizingMaskIntoConstraints = false

        [meter, numbers, transcript, scroll, hint].forEach { content.addSubview($0) }

        NSLayoutConstraint.activate([
            meter.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            meter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            meter.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            meter.heightAnchor.constraint(equalToConstant: 18),

            numbers.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 8),
            numbers.leadingAnchor.constraint(equalTo: meter.leadingAnchor),
            numbers.trailingAnchor.constraint(equalTo: meter.trailingAnchor),

            transcript.topAnchor.constraint(equalTo: numbers.bottomAnchor, constant: 6),
            transcript.leadingAnchor.constraint(equalTo: meter.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: meter.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: meter.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: meter.trailingAnchor),

            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: meter.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: meter.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        // The meter starts with the window, not with the controller.
    }

    func update(level: Float, background: Float) {
        guard isVisible else { return }
        peakHold = max(peakHold, level)
        // One read of the setting, not two: this runs about 24 times a second.
        let config = Prefs.sensitivity.config
        let threshold = max(config.absoluteThreshold, background * config.attackRatio)
        numbers.stringValue = String(
            format: "level %.4f   background %.4f   threshold %.4f",
            level, background, threshold)
    }

    func setTranscript(_ text: String) {
        guard isVisible else { return }
        transcript.stringValue = text.isEmpty ? "…" : "\u{201C}\(text)\u{201D}"
    }

    /// Appended through the text storage rather than `string +=`, which copied
    /// and re-laid out the entire log for every line.
    func append(_ line: String) {
        let entry = "[\(Self.stamper.string(from: Date()))] \(line)\n"
        guard let storage = logView.textStorage else {
            logView.string += entry
            return
        }
        storage.append(NSAttributedString(string: entry, attributes: [
            .font: logView.font ?? .monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        logLines += 1
        trimLogIfNeeded(storage)
        if isVisible { logView.scrollToEndOfDocument(nil) }
    }

    private func trimLogIfNeeded(_ storage: NSTextStorage) {
        guard logLines > Self.maxLogLines else { return }
        let text = storage.string as NSString
        var cut = 0
        var dropped = 0
        while dropped < logLines - Self.maxLogLines {
            let newline = text.range(of: "\n", range: NSRange(location: cut,
                                                             length: text.length - cut))
            guard newline.location != NSNotFound else { break }
            cut = newline.location + 1
            dropped += 1
        }
        guard cut > 0 else { return }
        storage.deleteCharacters(in: NSRange(location: 0, length: cut))
        logLines -= dropped
    }
}
