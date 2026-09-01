import Foundation
import Speech
import AVFoundation
import os

/// Wraps SFSpeechRecognizer as a short, on-demand listening window.
///
/// Nothing is transcribed until a double clap opens the window, and the window
/// closes itself after a few seconds — so the mic stream only ever reaches the
/// recognizer for a moment at a time.
final class SpeechListener {

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutWork: DispatchWorkItem?

    /// `append` runs on the audio thread while `start`/`stop` run on main, so the
    /// request handoff is guarded. Uncontended in practice — main only touches it
    /// twice per trigger.
    private var lock = os_unfair_lock()

    private(set) var isListening = false

    /// The recogniser delivers results on its own queue while the timeout and
    /// the finish path read this from main, so it goes through the same lock
    /// rather than being torn between the two.
    private var _latestTranscript = ""
    private var latestTranscript: String {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _latestTranscript
        }
        set {
            os_unfair_lock_lock(&lock)
            _latestTranscript = newValue
            os_unfair_lock_unlock(&lock)
        }
    }

    var onPartial: ((String) -> Void)?
    var onEnd: ((String?) -> Void)?     // nil transcript = failed / nothing heard

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    static func requestAuthorization(_ done: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status) }
        }
    }

    static var authorization: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Opens a listening window. Buffers must be fed in with `append`.
    /// `vocabulary` biases recognition toward words it would otherwise mangle —
    /// "Jarvis", "Schoology", "the craft".
    func start(timeout: TimeInterval, vocabulary: [String] = []) {
        stop(deliverEnd: false)

        guard let recognizer, recognizer.isAvailable else {
            onEnd?(nil)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Keep audio on the Mac when the language model is installed locally.
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        // .unspecified, not .confirmation: that hint tells the recogniser to expect
        // a short yes/no answer, which mangles command phrases like
        // "jarvis, launch claude".
        req.taskHint = .unspecified
        if !vocabulary.isEmpty {
            req.contextualStrings = Array(vocabulary.prefix(100))
        }

        os_unfair_lock_lock(&lock)
        request = req
        isListening = true
        os_unfair_lock_unlock(&lock)

        latestTranscript = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let latest = result.bestTranscription.formattedString
                self.latestTranscript = latest
                DispatchQueue.main.async { self.onPartial?(latest) }
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    guard self.isListening else { return }
                    self.finishWithLatest()
                }
            }
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            self.finishWithLatest()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Pushes the end of the listening window further out — used when a command
    /// is clearly still being dictated.
    func extend(to seconds: TimeInterval) {
        guard isListening, let existing = timeoutWork else { return }
        existing.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isListening else { return }
            self.finishWithLatest()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&lock)
        let target = request
        os_unfair_lock_unlock(&lock)
        target?.append(buffer)
    }

    /// One read of the transcript behind the lock, so the emptiness test and
    /// the value delivered can't come from two different moments.
    private func finishWithLatest() {
        let text = latestTranscript
        finish(with: text.isEmpty ? nil : text)
    }

    /// Called from the recognizer/timeout path — tears down and reports.
    private func finish(with transcript: String?) {
        stop(deliverEnd: false)
        onEnd?(transcript)
    }

    func stop(deliverEnd: Bool = true) {
        timeoutWork?.cancel()
        timeoutWork = nil

        os_unfair_lock_lock(&lock)
        let wasListening = isListening
        let target = request
        isListening = false
        request = nil
        os_unfair_lock_unlock(&lock)

        target?.endAudio()
        task?.cancel()
        task = nil

        if deliverEnd && wasListening { onEnd?(nil) }
    }
}
