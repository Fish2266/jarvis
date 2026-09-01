import AVFoundation
import AppKit
import os

enum ListenerState: Equatable {
    case off
    case noPermission
    case listening          // waiting for a double clap
    case armed              // double clap heard, listening for a command
    case thinking           // deterministic match failed, asking the model
    case triggered
    case failed(String)
}

/// Owns the microphone tap and drives clap -> command -> action.
///
/// Resolution is tiered so the thing that matters (opening your app) never waits
/// on a model:
///   1. `Resolver` — pure string matching, instant, handles the normal case.
///   2. `Intelligence.resolve` — only when tier 1 finds nothing.
///   3. `Intelligence.reply` — after the action already ran, purely for the voice line.
final class ListenerEngine {

    private let engine = AVAudioEngine()
    private let detector = ClapDetector()
    private let speech = SpeechListener()

    private(set) var state: ListenerState = .off {
        didSet { if state != oldValue { onState?(state) } }
    }

    var onState: ((ListenerState) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    var onLog: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?

    private var tapInstalled = false
    private var phraseWindow: TimeInterval = 6.0

    private var macros: [Macro] = MacroStore.load()
    private var lastHeard = ""
    /// Fires once dictation has stopped changing, for commands that capture text.
    private var settleWork: DispatchWorkItem?
    /// How long the transcript must hold still before a dictated command runs.
    private let dictationSettle: TimeInterval = 1.1
    /// Shorter pause for ordinary commands. Any command can still grow — "open
    /// chrome" becomes "open chrome on work" — so none of them fire on sight.
    private let commandSettle: TimeInterval = 0.6
    private var didFire = false
    /// Bumped on every arm and cancel so late async work can tell it's stale.
    private var runID = 0

    init() {
        detector.config = Prefs.sensitivity.config
        wireDetector()
        wireSpeech()

        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
        NotificationCenter.default.addObserver(
            forName: .macrosChanged, object: nil, queue: .main) { [weak self] _ in
                self?.macros = MacroStore.load()
            }

        EscapeHotKey.shared.onPress = { [weak self] in self?.cancel() }
        AppIndex.shared.ensureLoaded()
    }

    private func wireDetector() {
        detector.onLevel = { [weak self] rms, bg in
            DispatchQueue.main.async { self?.onLevel?(rms, bg) }
        }
        detector.onClap = { [weak self] index in
            DispatchQueue.main.async {
                self?.log(index == 1 ? "clap (waiting for a second…)" : "clap 2")
            }
        }
        detector.onRejected = { [weak self] peak in
            DispatchQueue.main.async {
                self?.log(String(format: "ignored a loud sound (peak %.3f) — didn't decay like a clap", peak))
            }
        }
        detector.onDoubleClap = { [weak self] in
            DispatchQueue.main.async { self?.handleDoubleClap() }
        }
    }

    private func wireSpeech() {
        speech.onPartial = { [weak self] text in
            guard let self, self.state == .armed, !self.didFire else { return }
            self.lastHeard = text
            self.onTranscript?(text)

            guard let resolution = Resolver.resolveFast(transcript: text, macros: self.macros)
            else {
                // Not a command — but it may be a question still being asked.
                if Prefs.answerQuestions, Questions.looksLikeQuestion(text) {
                    self.speech.extend(to: self.dictationSettle + 6)
                    self.scheduleSettle(after: self.dictationSettle)
                }
                return
            }

            // Nothing fires on sight. A partial that parses may still be the
            // start of a longer sentence — "open chrome" grows into "open chrome
            // on work", "remind me in" into a whole reminder — so wait for the
            // words to stop arriving and act on what's actually there.
            if resolution.macro.kind.capturesText {
                self.speech.extend(to: self.dictationSettle + 6)
                self.scheduleSettle(after: self.dictationSettle)
            } else {
                self.scheduleSettle(after: self.commandSettle)
            }
        }

        speech.onEnd = { [weak self] text in
            guard let self, self.state == .armed, !self.didFire else { return }
            self.settleWork?.cancel()
            guard let text, !text.isEmpty else {
                self.log("nothing heard, standing down")
                self.standDown()
                return
            }
            self.resolveAndAct(text)
        }
    }

    // MARK: - Permissions

    func requestPermissions(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micGranted in
            guard micGranted else {
                DispatchQueue.main.async { done(false) }
                return
            }
            SpeechListener.requestAuthorization { status in
                if status != .authorized {
                    self.log("speech recognition not authorized (\(status.rawValue))")
                }
                done(true)
            }
        }
    }

    var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Run loop

    func start() {
        guard micAuthorized else {
            state = .noPermission
            return
        }
        guard !engine.isRunning else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            state = .failed("No usable audio input device.")
            return
        }

        detector.reset()
        detector.config = Prefs.sensitivity.config

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.handle(buffer: buffer, sampleRate: format.sampleRate)
            }
            tapInstalled = true
        }

        engine.prepare()
        do {
            try engine.start()
            state = .listening
            log("listening on \(inputDeviceName()) @ \(Int(format.sampleRate)) Hz")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        settleWork?.cancel()
        speech.stop(deliverEnd: false)
        EscapeHotKey.shared.unregister()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        detector.resetSequence()
        state = .off
    }

    func restart() { stop(); start() }

    func applySensitivity() { detector.config = Prefs.sensitivity.config }

    func reloadMacros() { macros = MacroStore.load() }

    @objc private func configurationChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != .off else { return }
            self.log("audio device changed — restarting")
            self.restart()
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channels = buffer.floatChannelData else { return }
        detector.process(channels[0], count: Int(buffer.frameLength), sampleRate: sampleRate)
        speech.append(buffer)
    }

    // MARK: - Sequence

    /// Start listening without clapping — used by the scripting hook, so you can
    /// bind a keyboard shortcut to it instead of (or as well as) the claps.
    func arm() { handleDoubleClap() }

    private func handleDoubleClap() {
        guard state == .listening else { return }
        log("double clap")

        guard SpeechListener.authorization == .authorized else {
            log("speech recognition isn't authorized — opening the first command instead")
            if let macro = macros.first(where: \.enabled) {
                execute(Resolution(macro: macro, confidence: 1, source: .macro), heard: "")
            }
            return
        }

        runID += 1
        didFire = false
        lastHeard = ""
        state = .armed
        chime(.armed)

        if Prefs.showHUD { HUDOverlay.shared.beginListening(seconds: phraseWindow) }
        EscapeHotKey.shared.register()
        log(EscapeHotKey.shared.isRegistered
            ? "escape armed — press Esc to cancel"
            : "warning: couldn't register the Escape hotkey")

        speech.start(timeout: phraseWindow, vocabulary: recognitionVocabulary())

        // Warmup last, and off the main thread. Spending the listening window
        // loading the model means tier 2 is warm if tier 1 misses.
        if Prefs.useModel { Intelligence.shared.prewarm() }
        Weather.shared.requestAuthorizationIfNeeded()
    }

    /// Words worth biasing the recogniser toward: the assistant's name and
    /// everything your commands are called.
    private func recognitionVocabulary() -> [String] {
        var words = ["Jarvis", "hey Jarvis"]
        for macro in macros where macro.enabled {
            words.append(macro.name)
            words.append(contentsOf: macro.phrases)
        }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Restarts the quiet-period timer. Whatever the transcript says when the
    /// speaker pauses is what runs.
    private func scheduleSettle(after delay: TimeInterval) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .armed, !self.didFire else { return }
            self.resolveAndAct(self.lastHeard)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Commands first, always. Only what the resolver can't place goes anywhere
    /// near the model, so opening an app never waits on one.
    private func resolveAndAct(_ text: String) {
        guard state == .armed || state == .thinking, !didFire else { return }

        if let resolution = Resolver.resolveFast(transcript: text, macros: macros) {
            execute(resolution, heard: text)
            return
        }
        if Prefs.answerQuestions, Questions.looksLikeQuestion(text) {
            answerQuestion(text)
            return
        }
        askTheModel(about: text)
    }

    /// "jarvis, how are you?" — answered out loud rather than matched to an app.
    private func answerQuestion(_ question: String) {
        guard Prefs.useModel, Intelligence.shared.isAvailable else {
            log("can't answer questions — Apple Intelligence is unavailable")
            standDown()
            return
        }

        didFire = true
        settleWork?.cancel()
        let id = runID
        EscapeHotKey.shared.unregister()
        speech.stop(deliverEnd: false)
        detector.resetSequence()
        state = .thinking
        chime(.triggered)
        log("question: \"\(question)\"")
        if Prefs.showHUD { HUDOverlay.shared.confirm(headline: "Thinking…") }

        // Some questions have an exact answer already — no need to ask, and no
        // chance of the model inventing one.
        if let known = Questions.localAnswer(for: question) {
            log("answer (local): \(known)")
            if Prefs.showHUD { HUDOverlay.shared.setAnswer(known) }
            if Prefs.speakReply { VoiceBox.shared.speak(known) }
            state = engine.isRunning ? .listening : .off
            return
        }

        Task { @MainActor in
            let reply = await Intelligence.shared.answer(question)
            guard id == self.runID else { return }
            let spoken = reply ?? "I haven't an answer for that, sir."
            self.log("answer: \(spoken)")
            if Prefs.showHUD { HUDOverlay.shared.setAnswer(spoken) }
            if Prefs.speakReply { VoiceBox.shared.speak(spoken) }
            self.state = self.engine.isRunning ? .listening : .off
        }
    }

    /// Tier 2 — only reached when the deterministic resolver found nothing.
    private func askTheModel(about text: String) {
        guard Prefs.useModel, Intelligence.shared.isAvailable else {
            log("no match for \"\(text)\", standing down")
            standDown()
            return
        }

        let id = runID
        state = .thinking
        if Prefs.showHUD { HUDOverlay.shared.setStatus("INTERPRETING") }
        log("no direct match for \"\(text)\" — asking the model")

        let candidates = Resolver.candidates(macros: macros)
        Task { @MainActor in
            let named = await Intelligence.shared.resolveTarget(
                transcript: text, commands: candidates.map(\.name))
            guard id == self.runID, !self.didFire else { return }

            // The model names a target; tier 1 decides whether that name is
            // actually something we can open.
            guard let named,
                  let resolution = Resolver.resolveNamed(named, macros: self.macros) else {
                self.log("model said \(named ?? "nothing") — no match, standing down")
                self.standDown()
                return
            }
            self.log("model read that as \(named) -> \(resolution.macro.name)")
            self.execute(resolution, heard: text)
        }
    }

    private func standDown() {
        settleWork?.cancel()
        EscapeHotKey.shared.unregister()
        speech.stop(deliverEnd: false)
        if Prefs.showHUD { HUDOverlay.shared.standDown() }
        detector.resetSequence()
        state = engine.isRunning ? .listening : .off
    }

    /// Escape pressed — abandon everything in flight.
    ///
    /// Deliberately unconditional: if the HUD is on screen, Escape clears it, no
    /// matter what the state machine thinks is happening.
    func cancel() {
        let wasActive = state == .armed || state == .thinking || state == .triggered
        guard wasActive || HUDOverlay.shared.isShowing else { return }
        runID += 1
        didFire = true
        settleWork?.cancel()
        log("cancelled")
        EscapeHotKey.shared.unregister()
        speech.stop(deliverEnd: false)
        VoiceBox.shared.stop()
        HUDOverlay.shared.cancel()
        AnswerBar.shared.dismiss()
        detector.resetSequence()
        if wasActive { state = engine.isRunning ? .listening : .off }
    }

    // MARK: - Executing a command

    private func execute(_ resolution: Resolution, heard: String) {
        guard !didFire else { return }
        didFire = true
        settleWork?.cancel()
        let id = runID
        var macro = resolution.macro
        // A spoken profile ("…on work") beats whatever the command is pinned to.
        if let spoken = resolution.chromeProfile { macro.chromeProfile = spoken }

        EscapeHotKey.shared.unregister()
        speech.stop(deliverEnd: false)
        detector.resetSequence()
        state = .triggered
        chime(.triggered)

        log(String(format: "%@ (%.2f via %@)", macro.actionLabel,
                   resolution.confidence, resolution.source.rawValue))

        if Prefs.showHUD { HUDOverlay.shared.confirm(headline: macro.actionLabel) }

        // The action runs now. Everything below this line is decoration.
        perform(macro, payload: resolution.payload,
                forceNewTab: resolution.forceNewTab) { [weak self] extra in
            guard let self, id == self.runID else { return }
            guard !macro.kind.handlesOwnReply else { return }
            self.speakReply(for: macro, heard: heard, extra: extra, id: id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
            guard let self, id == self.runID, self.state == .triggered else { return }
            self.state = self.engine.isRunning ? .listening : .off
        }
    }

    /// `completion` carries any result worth mentioning in the spoken line.
    private func perform(_ macro: Macro, payload: String?, forceNewTab: Bool = false,
                         completion: @escaping (String?) -> Void) {
        switch macro.kind {
        case .app:
            // Chrome with a profile goes through the profile-aware launcher so
            // "open chrome on work" lands in the right window.
            if macro.chromeProfile != nil,
               macro.target == Browser.chromeURL()?.path {
                Browser.open(nil, chromeProfile: macro.chromeProfile)
                completion(nil)
                return
            }
            let url = URL(fileURLWithPath: macro.target)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                DispatchQueue.main.async {
                    if let error {
                        self?.log("couldn't open \(macro.name): \(error.localizedDescription)")
                        if Prefs.showHUD { HUDOverlay.shared.setDetail("Couldn't open \(macro.name)") }
                    }
                    completion(nil)
                }
            }

        case .url:
            let openFresh: () -> Void = { [weak self] in
                if Browser.open(macro.target, chromeProfile: macro.chromeProfile) {
                    if let profile = Browser.profileName(for: macro.chromeProfile) {
                        self?.log("opened \(macro.target) in Chrome profile \(profile)")
                    }
                } else {
                    self?.log("bad URL for \(macro.name): \(macro.target)")
                    if Prefs.showHUD { HUDOverlay.shared.setDetail("Couldn't open \(macro.name)") }
                }
                completion(nil)
            }

            // Chrome doesn't tell scripts which profile a window belongs to, so a
            // command pinned to a profile hands the picker the account it wants
            // and the accounts it doesn't; it declines rather than risk landing
            // on the same site in the other profile. See Browser.pickTab.
            guard Prefs.reuseTabs, !forceNewTab else { openFresh(); return }
            Browser.focusExistingTab(
                matching: macro.target,
                profileEmail: Browser.profileEmail(for: macro.chromeProfile),
                otherEmails: Browser.otherProfileEmails(excluding: macro.chromeProfile)
            ) { [weak self] focused in
                guard focused else { openFresh(); return }
                self?.log("switched to the open \(macro.name) tab")
                if Prefs.showHUD { HUDOverlay.shared.setHeadline("Switching to \(macro.name)") }
                completion(nil)
            }

        case .reminder:
            Reminders.add(payload ?? "", listName: macro.target.isEmpty ? nil : macro.target) {
                [weak self] result in
                switch result {
                case .success(let summary):
                    self?.log("reminder added: \(summary)")
                    if Prefs.showHUD { HUDOverlay.shared.setHeadline(summary) }
                    completion("Added a reminder: \(summary)")
                case .failure(let error):
                    self?.log("reminder failed: \(error.localizedDescription)")
                    if Prefs.showHUD {
                        HUDOverlay.shared.setHeadline("Couldn't add that reminder")
                        HUDOverlay.shared.setDetail(error.localizedDescription)
                    }
                    completion(nil)
                }
            }

        case .sleep:
            // Say goodnight first, then sleep, so the line isn't cut off.
            let line = "Goodnight, sir."
            if Prefs.showHUD { HUDOverlay.shared.setDetail(line) }
            if Prefs.speakReply { VoiceBox.shared.speak(line) }
            log("sleeping the Mac")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                if !SystemPower.sleepNow() { self.log("couldn't sleep the Mac") }
            }
            completion(nil)

        case .weather:
            Weather.shared.current { [weak self] result in
                switch result {
                case .success(let summary):
                    self?.log("weather: \(summary)")
                    if Prefs.showHUD { HUDOverlay.shared.setHeadline(summary) }
                    completion(summary)
                case .failure(let error):
                    self?.log("weather failed: \(error.localizedDescription)")
                    if Prefs.showHUD {
                        HUDOverlay.shared.setHeadline("Weather unavailable")
                        HUDOverlay.shared.setDetail(error.localizedDescription)
                    }
                    completion(nil)
                }
            }
        }
    }

    // MARK: - The voice line (never blocks anything)

    private func speakReply(for macro: Macro, heard: String, extra: String?, id: Int) {
        guard Prefs.speakReply || Prefs.showHUD else { return }

        var action = macro.actionLabel
        if let extra { action += ": \(extra)" }

        if !Prefs.useModel || !Intelligence.shared.isAvailable {
            let line = Intelligence.cannedReplies.randomElement() ?? "Right away, sir."
            deliver(line, id: id)
            return
        }

        Task { @MainActor in
            let line = await Intelligence.shared.reply(action: action, heard: heard)
            guard id == self.runID else { return }
            self.deliver(line, id: id)
        }
    }

    private func deliver(_ line: String, id: Int) {
        guard id == runID else { return }
        if Prefs.showHUD { HUDOverlay.shared.setDetail(line) }
        guard Prefs.speakReply else { return }

        VoiceBox.shared.speak(line)
    }

    /// Run one command directly — the "Try it now" button in the editor.
    func run(_ macro: Macro, payload: String? = nil) {
        runID += 1
        didFire = false
        execute(Resolution(macro: macro, confidence: 1, source: .macro, payload: payload),
                heard: "")
    }

    /// Answer a question directly, without waiting on the microphone.
    func ask(_ question: String) {
        runID += 1
        didFire = false
        state = .armed
        answerQuestion(question)
    }

    /// Run a command by name, optionally with text for a capture command.
    func run(named name: String, text: String?) {
        let wanted = PhraseMatcher.normalize(name)
        guard let macro = macros.first(where: {
            $0.enabled && PhraseMatcher.normalize($0.name) == wanted
        }) else {
            log("no command named \"\(name)\"")
            return
        }
        run(macro, payload: text)
    }

    /// Menu "Test the trigger" and the scripting hook.
    func fire() {
        guard let macro = macros.first(where: \.enabled) else {
            log("no commands defined")
            return
        }
        runID += 1
        didFire = false
        execute(Resolution(macro: macro, confidence: 1, source: .macro), heard: "")
    }

    // MARK: - Feedback

    private enum Chime { case armed, triggered }

    private func chime(_ kind: Chime) {
        guard Prefs.playSounds else { return }
        NSSound(named: NSSound.Name(kind == .armed ? "Tink" : "Hero"))?.play()
    }

    private func inputDeviceName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "default input"
    }

    private static let logger = Logger(subsystem: "com.connorchristopherson.Jarvis",
                                       category: "engine")

    private func log(_ message: String) {
        // Mirrored to the system log so `log stream` can follow what Jarvis is
        // doing without the Clap Monitor window open.
        Self.logger.notice("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }
}
