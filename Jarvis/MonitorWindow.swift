import AppKit

/// Live view of what the detector is hearing. Useful for picking a sensitivity:
/// clap and watch whether the peak clears the threshold line.
final class MonitorWindow: NSWindowController {

    private let meter = NSLevelIndicator()
    private let numbers = NSTextField(labelWithString: "")
    private let transcript = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private var peakHold: Float = 0
    private var peakDecayTimer: Timer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Jarvis — Clap Monitor"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
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

        peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.peakHold *= 0.86
            self.meter.floatValue = min(1, self.peakHold * 4)
        }
    }

    func update(level: Float, background: Float) {
        peakHold = max(peakHold, level)
        let threshold = max(Prefs.sensitivity.config.absoluteThreshold,
                            background * Prefs.sensitivity.config.attackRatio)
        numbers.stringValue = String(
            format: "level %.4f   background %.4f   threshold %.4f",
            level, background, threshold)
    }

    func setTranscript(_ text: String) {
        transcript.stringValue = text.isEmpty ? "…" : "\u{201C}\(text)\u{201D}"
    }

    func append(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logView.string += "[\(stamp)] \(line)\n"
        logView.scrollToEndOfDocument(nil)
    }
}
