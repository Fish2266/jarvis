import AVFoundation
import AppKit
import CoreGraphics
import os

enum ListenerState: Equatable {
    case off
    case noPermission
    case listening          // waiting for a double clap
    case armed              // double clap heard, listening for a command
    case watching           // nothing said — the camera has the window to itself
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
    private let hands = HandTracker()

    private(set) var state: ListenerState = .off {
        didSet { if state != oldValue { onState?(state) } }
    }

    var onState: ((ListenerState) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    /// Set only while the Clap Monitor is on screen.
    ///
    /// The detector reports a level about twenty-four times a second, forever,
    /// and each report used to hop to the main queue whether or not anything
    /// was drawing it. That is a main-thread wake-up twice a second per idle
    /// hour on a laptop that is otherwise doing nothing — cheap in CPU, not
    /// free in battery, and this app is meant to run all day.
    var wantsLevels = false
    var onLog: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    /// Set only while the Clap Monitor is on screen, same bargain as `wantsLevels`.
    var onPreview: ((CGImage?, [CameraPreviewView.Hand], String) -> Void)?
    var onCameraStopped: (() -> Void)?

    private var tapInstalled = false
    private var phraseWindow: TimeInterval = 6.0

    /// How long the camera stays open after a double clap. Longer than the
    /// phrase window on purpose: saying nothing is how you ask for a gesture,
    /// and the microphone has to be allowed to give up first.
    private let gestureWindow: TimeInterval = 8.0
    /// How much longer it stays open after a gesture lands, so moving two
    /// desktops over doesn't need a second double clap.
    private let gestureChain: TimeInterval = 2.5
    /// How long words keep the camera muted after the last one arrived.
    ///
    /// Must be longer than `dictationSettle`, and is: a phrase that is about to
    /// resolve into a command has to get there before a hand that happens to be
    /// moving can, or both would fire.
    private let speechGrace: TimeInterval = 1.4

    /// Whether the camera is open for the phrase in progress.
    private var watching = false
    private var watchWork: DispatchWorkItem?
    /// Clap Monitor's "Camera check": the camera runs without a clap, and
    /// gestures are reported rather than performed.
    private(set) var cameraCheck = false
    /// Whether this phrase's camera clock has been restarted from the moment
    /// frames began. Once only — a chained gesture must not win a fresh window
    /// by way of the camera reporting itself ready again.
    private var watchStarted = false

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
    /// Block-based observers aren't torn down with their owner — keep the token.
    private var macrosObserver: NSObjectProtocol?

    init() {
        detector.config = Prefs.sensitivity.config
        wireDetector()
        wireSpeech()
        wireHands()

        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
        macrosObserver = NotificationCenter.default.addObserver(
            forName: .macrosChanged, object: nil, queue: .main) { [weak self] _ in
                self?.macros = MacroStore.load()
            }

        EscapeHotKey.shared.onPress = { [weak self] in self?.cancel() }
        AppIndex.shared.ensureLoaded()
    }

    deinit {
        if let macrosObserver { NotificationCenter.default.removeObserver(macrosObserver) }
        NotificationCenter.default.removeObserver(self)
    }

    private func wireDetector() {
        detector.onLevel = { [weak self] rms, bg in
            // Read from the audio thread, written from main. A Bool is a single
            // byte and cannot tear; the worst case is one stale frame, which
            // costs a meter update nobody was looking at.
            guard let self, self.wantsLevels else { return }
            DispatchQueue.main.async { self.onLevel?(rms, bg) }
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

    private func wireHands() {
        hands.onLog = { [weak self] line in self?.log(line) }
        hands.onGesture = { [weak self] gesture in self?.handle(gesture) }
        hands.onPreview = { [weak self] image, drawn, note in
            self?.onPreview?(image, drawn, note)
        }
        // Opening a camera cold takes seconds — five, the first time, measured.
        // Counting those against the window meant the very first gesture after
        // launch had no chance at all: the window closed before a single frame
        // arrived. So the clock starts when the camera does.
        hands.onReady = { [weak self] in
            guard let self, self.watching, !self.watchStarted else { return }
            self.watchStarted = true
            self.log("camera ready")
            self.scheduleWatchEnd(after: self.gestureWindow)
        }
    }

    /// Opens the capture session ahead of time, without starting it.
    ///
    /// The first double clap of a session used to spend five seconds — measured
    /// — opening the camera, which is most of the window you have to gesture in.
    /// The window now waits for the camera, but waiting is still waiting.
    func prewarmCamera() {
        guard Prefs.gestures else { return }
        hands.prepare()
    }

    /// The Clap Monitor coming and going. Preview frames cost a scale and a
    /// colour conversion each, so they are only produced while something is
    /// drawing them.
    func wantsPreview(_ wanted: Bool) { hands.wantsPreview(wanted) }

    /// Runs the camera with no clap and no consequences, for working out why a
    /// gesture isn't landing. Eight seconds at a time is no way to debug this.
    func setCameraCheck(_ on: Bool) {
        guard cameraCheck != on else { return }
        cameraCheck = on
        if on {
            guard HandTracker.authorized else {
                log("camera check: no camera access")
                cameraCheck = false
                return
            }
            log("camera check on — nothing will be performed")
            hands.start()
        } else {
            log("camera check off")
            if !watching { hands.stop() }
            onCameraStopped?()
        }
    }

    private func wireSpeech() {
        speech.onPartial = { [weak self] text in
            guard let self, self.state == .armed, !self.didFire else { return }
            self.lastHeard = text

            // Words are arriving, so the camera stops looking. A hand moving
            // while you talk is you talking with your hands — and this is the
            // half of the bargain that says a spoken command wins.
            if !text.isEmpty { self.hands.mute(for: self.speechGrace) }
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
                // Saying nothing is not a failure here — it's the other half of
                // the bargain. `standDown` keeps the camera if it's still open.
                self.log(self.watching ? "nothing said — over to the camera"
                                       : "nothing heard, standing down")
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
                // Asked for now rather than in the middle of a phrase: granting
                // the camera is not the same as turning it on, and a permission
                // sheet dropping over the screen two seconds after a double clap
                // is a poor way to find out the feature exists.
                //
                // Not *in front of* the microphone, though. `done` starts the
                // whole listener, and nothing about hearing you should wait on
                // an answer about the camera — a dialog left sitting there
                // unanswered would otherwise mean Jarvis never starts at all.
                if Prefs.gestures, HandTracker.authorization == .notDetermined {
                    HandTracker.requestAccess { granted in
                        if !granted { self.log("camera denied — gestures are off") }
                    }
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
        stopWatching()
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
                // Reset here too: `execute` refuses to fire while `didFire` is
                // set, and the reset below is past this early return — so
                // without this, this fallback worked exactly once per launch.
                runID += 1
                didFire = false
                execute(Resolution(macro: macro, confidence: 1, source: .macro), heard: "")
            }
            return
        }

        runID += 1
        didFire = false
        lastHeard = ""
        state = .armed
        chime(.armed)

        startWatching()

        if Prefs.showHUD {
            HUDOverlay.shared.beginListening(seconds: watching ? gestureWindow : phraseWindow)
        }
        EscapeHotKey.shared.register()
        log(EscapeHotKey.shared.isRegistered
            ? "escape armed — press Esc to cancel"
            : "warning: couldn't register the Escape hotkey")

        speech.start(timeout: phraseWindow, vocabulary: recognitionVocabulary())

        // Warmup last, and off the main thread. Spending the listening window
        // loading the model means tier 2 is warm if tier 1 misses.
        if Prefs.useModel { Intelligence.shared.prewarm() }
        Weather.shared.requestAuthorizationIfNeeded()
        // Anything installed since launch becomes reachable by name. Off the
        // main thread, and at most once every few minutes.
        AppIndex.shared.refreshIfStale(after: AppIndex.staleAfter)
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
        stopWatching()
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

    /// The microphone is done with this phrase — either it heard nothing, or
    /// what it heard was nothing we could use.
    ///
    /// That is not the end of the phrase if the camera is still open. It is
    /// precisely the case the camera exists for, so the reticle stays up, Escape
    /// stays armed, and the window closes on its own when `watchWork` fires.
    private func standDown() {
        settleWork?.cancel()
        speech.stop(deliverEnd: false)
        detector.resetSequence()

        if watching {
            state = .watching
            if Prefs.showHUD { HUDOverlay.shared.setStatus("WATCHING") }
            return
        }

        EscapeHotKey.shared.unregister()
        if Prefs.showHUD { HUDOverlay.shared.standDown() }
        state = engine.isRunning ? .listening : .off
    }

    /// Escape pressed — abandon everything in flight.
    ///
    /// Deliberately unconditional: if the HUD is on screen, Escape clears it, no
    /// matter what the state machine thinks is happening.
    func cancel() {
        let wasActive = state == .armed || state == .watching
            || state == .thinking || state == .triggered
        guard wasActive || HUDOverlay.shared.isShowing else { return }
        runID += 1
        didFire = true
        settleWork?.cancel()
        log("cancelled")
        EscapeHotKey.shared.unregister()
        speech.stop(deliverEnd: false)
        stopWatching()
        VoiceBox.shared.stop()
        HUDOverlay.shared.cancel()
        AnswerBar.shared.dismiss()
        detector.resetSequence()
        if wasActive { state = engine.isRunning ? .listening : .off }
    }

    // MARK: - Gestures

    /// Opens the camera for this phrase.
    ///
    /// Never called from anywhere but a double clap, which is the whole promise:
    /// the camera is off, and then for eight seconds it isn't, and then it's off
    /// again. Every path that ends a phrase calls `stopWatching`.
    private func startWatching() {
        guard Prefs.gestures else { return }
        guard HandTracker.authorized else {
            if HandTracker.authorization == .denied {
                log("camera access is off — gestures are unavailable")
            }
            return
        }
        watching = true
        watchStarted = cameraCheck      // already live, so the clock is honest
        hands.start()
        scheduleWatchEnd(after: gestureWindow)
        log("camera on — watching for a gesture")
    }

    private func stopWatching() {
        watchWork?.cancel()
        watchWork = nil
        guard watching else { return }
        watching = false
        // Camera check outlives the phrase — it was switched on by hand and is
        // switched off the same way.
        guard !cameraCheck else { return }
        hands.stop()
        onCameraStopped?()
    }

    /// (Re)arms the camera's deadline. Used both to open the window and to push
    /// it out after a gesture lands.
    private func scheduleWatchEnd(after seconds: TimeInterval) {
        watchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.watching else { return }
            self.log("camera off")
            self.stopWatching()
            // `watching` is false now, so this does the real teardown.
            if self.state == .watching || self.state == .triggered { self.standDown() }
        }
        watchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A gesture landed.
    ///
    /// It beats the microphone outright: whatever was being said is abandoned
    /// and the listening window closes, which is the mirror image of a spoken
    /// command closing the camera. The camera itself stays open a little longer,
    /// so moving two desktops over is one thought rather than two double claps.
    private func handle(_ gesture: Gesture) {
        // Camera check only stands in for the real thing while nothing is armed.
        // Clapping and *then* gesturing is a genuine request and has to behave
        // like one — a debug view that quietly swallows real commands is worse
        // than no debug view, because it makes the feature look broken.
        guard watching else {
            guard cameraCheck else { return }
            let would = perform(gesture, dryRun: true)
            log("camera check: would fire \(would.headline)"
                + (would.detail.isEmpty ? "" : " — \(would.detail)")
                + " — clap first to actually run it")
            return
        }
        guard state == .armed || state == .watching || state == .triggered else { return }

        // Stop listening. `didFire` shuts every voice path — the settle timer,
        // a late `onEnd`, an in-flight model call — and bumping `runID` makes
        // sure anything already in the air lands stale.
        runID += 1
        didFire = true
        settleWork?.cancel()
        speech.stop(deliverEnd: false)
        detector.resetSequence()

        // The reticle goes first, so the screen is already clear as Mission
        // Control arrives. No confirmation burst either: a gesture should feel
        // like reaching out and moving the desktop yourself, and the desktop
        // moving *is* the feedback — a full-screen flash announcing what you
        // just watched happen only gets in the way, and a cyan ring hanging
        // over Mission Control for another few seconds is worse. Spoken
        // commands keep both, because there the HUD is the only thing that
        // says it heard you correctly.
        HUDOverlay.shared.dismissNow()
        perform(gesture)
        state = .triggered
        chime(.triggered)

        // Deliberately no spoken reply. You are mid-motion and may well swipe
        // again in a moment; a generated line per swipe would queue up behind
        // itself and still be talking three desktops later.
        scheduleWatchEnd(after: gestureChain)

        let id = runID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, id == self.runID, self.state == .triggered else { return }
            self.state = self.watching ? .watching
                                       : (self.engine.isRunning ? .listening : .off)
        }
    }

    @discardableResult
    private func perform(_ gesture: Gesture,
                         dryRun: Bool = false) -> (headline: String, detail: String) {
        let rerouted = gesture.action(canSwitchDesktops: Spaces.canSwitchDesktops)

        switch rerouted {
        case .missionControl:
            let why = rerouted == gesture
                ? "hands apart"
                : "hand \(gesture == .desktopLeft ? "right" : "left"), and desktop "
                  + "switching needs Accessibility"
            guard !dryRun else {
                return ("Mission Control", rerouted == gesture ? "" : "instead of a desktop switch")
            }
            log("gesture: \(why) -> Mission Control")
            guard Spaces.missionControl() else {
                log("couldn't open Mission Control")
                return ("Mission Control", "Couldn't open it")
            }
            return ("Mission Control", "")

        case .desktopLeft, .desktopRight:
            let direction: Spaces.Direction = rerouted == .desktopLeft ? .left : .right
            let moved = rerouted == .desktopLeft ? "right" : "left"
            guard !dryRun else {
                return ("Desktop \(direction.label)", "hand went \(moved)")
            }
            log("gesture: hand \(moved) -> desktop on the \(direction.label)")
            guard Spaces.switchDesktop(direction) else {
                // Only reachable if the grant is withdrawn between the check
                // above and here, which is a race worth surviving rather than
                // a state worth designing for.
                log("couldn't switch desktops")
                return ("Desktop \(direction.label)", "Couldn't switch")
            }
            return ("Desktop \(direction.label)", "")
        }
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
        // A command was said, so the camera has nothing left to decide.
        stopWatching()
        detector.resetSequence()
        state = .triggered
        chime(.triggered)

        // Whether this is really "make me a tab" rather than "open the browser".
        // Decided once, because the action and the HUD line have to agree — and
        // a pinned profile rules it out either way: Chrome tells scripts nothing
        // about profiles, so only the profile-aware launcher can land a window
        // in the right one.
        let fresh: Browser.Fresh? = {
            guard let fresh = resolution.browserFresh,
                  macro.kind == .app, macro.chromeProfile == nil,
                  macro.target == Browser.chromeURL()?.path
            else { return nil }
            return fresh
        }()

        // "bring over xcode" is a different action from "open xcode", and the
        // HUD and the spoken line should both say so.
        let label: String
        if resolution.bringHere && macro.kind.canBeBrought {
            label = "Bringing \(macro.name) over"
        } else if let fresh {
            label = fresh == .tab ? "New tab" : "New window"
        } else {
            label = macro.actionLabel
        }

        log(String(format: "%@ (%.2f via %@)", label,
                   resolution.confidence, resolution.source.rawValue))

        if Prefs.showHUD { HUDOverlay.shared.confirm(headline: label) }

        // The action runs now. Everything below this line is decoration.
        perform(macro, payload: resolution.payload,
                forceNewTab: resolution.forceNewTab,
                bringHere: resolution.bringHere,
                browserFresh: fresh, id: id) { [weak self] extra in
            guard let self, id == self.runID else { return }
            guard !macro.kind.handlesOwnReply else { return }
            self.speakReply(action: label, heard: heard, extra: extra, id: id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
            guard let self, id == self.runID, self.state == .triggered else { return }
            self.state = self.engine.isRunning ? .listening : .off
        }
    }

    /// `completion` carries any result worth mentioning in the spoken line.
    private func perform(_ macro: Macro, payload: String?, forceNewTab: Bool = false,
                         bringHere: Bool = false,
                         browserFresh: Browser.Fresh? = nil, id: Int = 0,
                         completion: @escaping (String?) -> Void) {
        switch macro.kind {
        case .app:
            // "bring over xcode": move its windows to this desktop *before*
            // activating, or activating would send us to the desktop it was on
            // and the move would be a visible yank back.
            if bringHere, let running = Spaces.runningApp(atPath: macro.target) {
                if Spaces.bring(pid: running.processIdentifier) {
                    log("brought \(macro.name) to this desktop")
                } else {
                    // No desktop move available — still better to focus it than
                    // to do nothing, which is what "open" would have done.
                    log("couldn't move \(macro.name) between desktops; focusing it instead")
                }
                running.activate(options: [.activateAllWindows])
                completion(nil)
                return
            }

            // "open a new tab". Opening an app that is already running only
            // brings its existing window forward, so Chrome has to be asked for
            // the tab directly.
            if let browserFresh {
                Browser.openFresh(browserFresh) { [weak self] made in
                    guard let self else { return }
                    if made {
                        self.log("new Chrome \(browserFresh.rawValue)")
                        completion(nil)
                    } else {
                        // Automation refused, or Chrome didn't answer in time.
                        self.log("couldn't make a new \(browserFresh.rawValue) — opening Chrome instead")
                        self.openApp(macro, id: id, completion: completion)
                    }
                }
                return
            }

            // Chrome with a profile goes through the profile-aware launcher so
            // "open chrome on work" lands in the right window — and reuses the
            // window already open for that profile instead of stacking up a new
            // one each time, the way opening any other running app would.
            if let profile = macro.chromeProfile, !profile.isEmpty,
               macro.target == Browser.chromeURL()?.path {
                Browser.openProfileWindow(profile,
                                          reuseExisting: Prefs.reuseTabs && !forceNewTab) {
                    [weak self] opened in
                    if !opened { self?.log("couldn't open Chrome in profile \(profile)") }
                    completion(nil)
                }
                return
            }
            openApp(macro, id: id, completion: completion)

        case .url:
            // Same reasoning as an app, one step earlier: bring the browser to
            // this desktop *before* a tab gets focused, or the AppleScript
            // activate that focuses it would drag us to the browser's desktop
            // and the move would look like a yank back.
            if bringHere, let chrome = Browser.chromeURL(),
               let running = Spaces.runningApp(atPath: chrome.path),
               Spaces.bring(pid: running.processIdentifier) {
                log("brought the browser to this desktop")
            }

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
                self?.ifCurrent(id) {
                    if Prefs.showHUD { HUDOverlay.shared.setHeadline("Switching to \(macro.name)") }
                }
                completion(nil)
            }

        case .reminder:
            Reminders.add(payload ?? "", listName: macro.target.isEmpty ? nil : macro.target) {
                [weak self] result in
                switch result {
                case .success(let summary):
                    self?.log("reminder added: \(summary)")
                    self?.ifCurrent(id) {
                        if Prefs.showHUD { HUDOverlay.shared.setHeadline(summary) }
                    }
                    completion("Added a reminder: \(summary)")
                case .failure(let error):
                    self?.log("reminder failed: \(error.localizedDescription)")
                    self?.ifCurrent(id) {
                        if Prefs.showHUD {
                            HUDOverlay.shared.setHeadline("Couldn't add that reminder")
                            HUDOverlay.shared.setDetail(error.localizedDescription)
                        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
                if !SystemPower.sleepNow() { self?.log("couldn't sleep the Mac") }
            }
            completion(nil)

        case .weather:
            Weather.shared.current { [weak self] result in
                switch result {
                case .success(let summary):
                    self?.log("weather: \(summary)")
                    self?.ifCurrent(id) {
                        if Prefs.showHUD { HUDOverlay.shared.setHeadline(summary) }
                    }
                    completion(summary)
                case .failure(let error):
                    self?.log("weather failed: \(error.localizedDescription)")
                    self?.ifCurrent(id) {
                        if Prefs.showHUD {
                            HUDOverlay.shared.setHeadline("Weather unavailable")
                            HUDOverlay.shared.setDetail(error.localizedDescription)
                        }
                    }
                    completion(nil)
                }
            }
        }
    }

    /// Runs `body` only if the command that started this is still the current
    /// one. A weather lookup or a reminder can land seconds after you have
    /// already asked for something else, and it used to repaint that newer
    /// command's HUD with its own result.
    private func ifCurrent(_ id: Int, _ body: () -> Void) {
        guard id == runID else { return }
        body()
    }

    /// Plain "open this": activates it if it's running, launches it if not.
    private func openApp(_ macro: Macro, id: Int = 0,
                         completion: @escaping (String?) -> Void) {
        let url = URL(fileURLWithPath: macro.target)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.log("couldn't open \(macro.name): \(error.localizedDescription)")
                    self?.ifCurrent(id) {
                        if Prefs.showHUD { HUDOverlay.shared.setDetail("Couldn't open \(macro.name)") }
                    }
                }
                completion(nil)
            }
        }
    }

    // MARK: - The voice line (never blocks anything)

    private func speakReply(action label: String, heard: String, extra: String?, id: Int) {
        guard Prefs.speakReply || Prefs.showHUD else { return }

        var action = label
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
