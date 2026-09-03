import AppKit
import ServiceManagement
import Speech
import AVFoundation

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let engine = ListenerEngine()
    private var monitor: MonitorWindow?
    private var commands: CommandsWindow?
    private var lastTranscript = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onState = { [weak self] state in self?.render(state) }
        engine.onLevel = { [weak self] rms, bg in self?.monitor?.update(level: rms, background: bg) }
        engine.onLog = { [weak self] line in self?.monitor?.append(line) }
        engine.onTranscript = { [weak self] text in
            self?.lastTranscript = text
            self?.monitor?.setTranscript(text)
        }
        engine.onPreview = { [weak self] image, hands, note in
            self?.monitor?.showCamera(image: image, hands: hands, note: note)
        }
        engine.onCameraStopped = { [weak self] in self?.monitor?.cameraStopped() }

        render(.off)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteTrigger),
            name: Notification.Name("com.connorchristopherson.Jarvis.trigger"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteArm),
            name: Notification.Name("com.connorchristopherson.Jarvis.arm"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showCommands),
            name: Notification.Name("com.connorchristopherson.Jarvis.commands"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteRun(_:)),
            name: Notification.Name("com.connorchristopherson.Jarvis.run"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteAsk(_:)),
            name: Notification.Name("com.connorchristopherson.Jarvis.ask"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCancel),
            name: Notification.Name("com.connorchristopherson.Jarvis.cancel"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(previewHUD),
            name: Notification.Name("com.connorchristopherson.Jarvis.previewHUD"), object: nil)

        if VoiceBox.onlyCompactVoicesInstalled && !Prefs.voiceNudgeShown {
            Prefs.voiceNudgeShown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.getVoices()
            }
        }

        TriggerHotKey.shared.onPress = { [weak self] in self?.engine.arm() }
        // Only while Jarvis is actually listening. A hot key is registered
        // globally, so binding one for a paused app takes the combination away
        // from everything else and then does nothing with it — `arm()` is a
        // no-op until the engine is running. Same bargain as `toggleEnabled`.
        if Prefs.enabled { applyTriggerShortcut() }

        engine.requestPermissions { [weak self] micGranted in
            guard let self else { return }
            if !micGranted {
                self.render(.noPermission)
                self.promptForMicrophone()
                return
            }
            if Prefs.enabled { self.engine.start() }
            // Once the microphone is up and there's nothing competing for the
            // main thread. Building the capture session does not turn the
            // camera on — that still needs a clap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.engine.prewarmCamera()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: - Status item

    private func render(_ state: ListenerState) {
        guard let button = statusItem.button else { return }

        let symbol: String
        switch state {
        case .off:          symbol = "hands.clap"
        case .noPermission: symbol = "exclamationmark.triangle"
        case .listening:    symbol = "hands.clap.fill"
        case .armed:        symbol = "mic.fill"
        case .watching:     symbol = "hand.raised.fill"
        case .thinking:     symbol = "ellipsis.circle.fill"
        case .triggered:    symbol = "bolt.fill"
        case .failed:       symbol = "exclamationmark.triangle.fill"
        }

        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jarvis")
            ?? NSImage(systemSymbolName: "hands.clap", accessibilityDescription: "Jarvis")
        button.image?.isTemplate = true
        button.toolTip = statusLine(state)
    }

    private func statusLine(_ state: ListenerState) -> String {
        switch state {
        case .off:           return "Paused"
        case .noPermission:  return "Microphone access denied"
        case .listening:     return "Listening — double clap, then say a command"
        case .armed:         return "Listening for a command (Esc to cancel)"
        case .watching:      return "Watching for a hand gesture (Esc to cancel)"
        case .thinking:      return "Working out what you meant…"
        case .triggered:     return "On it…"
        case .failed(let m): return "Error: \(m)"
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(engine.state), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !lastTranscript.isEmpty {
            let heard = NSMenuItem(title: "    \u{201C}\(lastTranscript)\u{201D}",
                                   action: nil, keyEquivalent: "")
            heard.isEnabled = false
            menu.addItem(heard)
        }

        menu.addItem(.separator())
        add(menu, "Enabled", #selector(toggleEnabled), checked: Prefs.enabled)

        let sensitivity = NSMenu()
        for level in Sensitivity.allCases {
            let item = NSMenuItem(title: level.title, action: #selector(pickSensitivity(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = level.rawValue
            item.state = (level == Prefs.sensitivity) ? .on : .off
            sensitivity.addItem(item)
        }
        let sensitivityItem = NSMenuItem(title: "Clap sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = sensitivity
        menu.addItem(sensitivityItem)

        let triggers = NSMenu()
        for shortcut in TriggerShortcut.allCases {
            let title = shortcut.note.map { "\(shortcut.title) — \($0)" } ?? shortcut.title
            let item = NSMenuItem(title: title, action: #selector(pickTrigger(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = shortcut.rawValue
            item.state = shortcut == Prefs.triggerShortcut ? .on : .off
            triggers.addItem(item)
        }
        // An unregistered hot key is not the same as a contested one: pausing
        // Jarvis hands the combination back deliberately, and reporting that as
        // a conflict sent you looking for a rival app that doesn't exist.
        if Prefs.triggerShortcut != .off, let note = triggerNote() {
            triggers.addItem(.separator())
            let line = NSMenuItem(title: "    \(note)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            triggers.addItem(line)
        }
        let triggerItem = NSMenuItem(title: "Keyboard trigger", action: nil, keyEquivalent: "")
        triggerItem.submenu = triggers
        menu.addItem(triggerItem)

        menu.addItem(.separator())
        add(menu, "Commands…", #selector(showCommands), key: ",")

        let weather = NSMenu()
        let f = NSMenuItem(title: "Fahrenheit", action: #selector(useFahrenheit), keyEquivalent: "")
        f.target = self; f.state = Prefs.useCelsius ? .off : .on
        weather.addItem(f)
        let c = NSMenuItem(title: "Celsius", action: #selector(useCelsius), keyEquivalent: "")
        c.target = self; c.state = Prefs.useCelsius ? .on : .off
        weather.addItem(c)
        weather.addItem(.separator())
        let loc = NSMenuItem(title: Prefs.manualLatitude == nil
                             ? "Using Location Services" : "Using a fixed location",
                             action: #selector(setLocation), keyEquivalent: "")
        loc.target = self
        weather.addItem(loc)
        let weatherItem = NSMenuItem(title: "Weather", action: nil, keyEquivalent: "")
        weatherItem.submenu = weather
        menu.addItem(weatherItem)

        menu.addItem(.separator())
        add(menu, "Reuse an open tab (no fixed profile)", #selector(toggleReuseTabs),
            checked: Prefs.reuseTabs)
        add(menu, "Show the HUD", #selector(toggleHUD), checked: Prefs.showHUD)

        let gestures = add(menu, "Hand gestures after a double clap",
                           #selector(toggleGestures), checked: Prefs.gestures)
        if Prefs.gestures, let note = gestureNote() {
            gestures.state = .mixed
            let line = NSMenuItem(title: "    \(note)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        add(menu, "Speak a reply", #selector(toggleSpeakReply), checked: Prefs.speakReply)

        let voices = NSMenu()
        let auto = NSMenuItem(title: "Best installed voice", action: #selector(pickVoice(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = Prefs.voiceIdentifier == nil ? .on : .off
        voices.addItem(auto)

        let groups = VoiceBox.grouped()
        let sections: [(String, [AVSpeechSynthesisVoice])] = [
            ("Premium", groups.premium),
            ("Enhanced", groups.enhanced),
            ("English (compact)", groups.english),
            ("Other languages", groups.other),
        ]
        var addedAny = false
        for (title, list) in sections where !list.isEmpty {
            if !addedAny { voices.addItem(.separator()); addedAny = true }
            let submenu = NSMenu()
            for voice in list {
                let item = NSMenuItem(title: "\(voice.name) — \(voice.language)",
                                      action: #selector(pickVoice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = voice.identifier
                item.state = Prefs.voiceIdentifier == voice.identifier ? .on : .off
                submenu.addItem(item)
            }
            let header = NSMenuItem(title: "\(title) (\(list.count))", action: nil, keyEquivalent: "")
            header.submenu = submenu
            voices.addItem(header)
        }

        if groups.premium.isEmpty && groups.enhanced.isEmpty {
            let note = NSMenuItem(title: "    No Enhanced or Premium voices installed",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            voices.addItem(note)
        }

        voices.addItem(.separator())
        let effects = NSMenuItem(title: "Tone shaping", action: #selector(toggleVoiceEffects),
                                 keyEquivalent: "")
        effects.target = self
        effects.state = Prefs.voiceEffects ? .on : .off
        voices.addItem(effects)

        let echo = NSMenu()
        for (title, amount) in [("Off", 0), ("Subtle", 8), ("Roomy", 18), ("Cavernous", 30)] {
            let item = NSMenuItem(title: title, action: #selector(pickReverb(_:)), keyEquivalent: "")
            item.target = self
            item.tag = amount
            item.state = Prefs.reverbAmount == amount ? .on : .off
            echo.addItem(item)
        }
        let echoItem = NSMenuItem(title: "Room echo", action: nil, keyEquivalent: "")
        echoItem.submenu = echo
        voices.addItem(echoItem)

        let preview = NSMenuItem(title: "Preview", action: #selector(previewVoice), keyEquivalent: "")
        preview.target = self
        voices.addItem(preview)

        voices.addItem(.separator())
        let get = NSMenuItem(title: "Where are my downloaded voices?…", action: #selector(getVoices),
                             keyEquivalent: "")
        get.target = self
        voices.addItem(get)

        let voicesItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voicesItem.submenu = voices
        menu.addItem(voicesItem)

        let intelligence = add(menu, "Use Apple Intelligence", #selector(toggleModel),
                               checked: Prefs.useModel)
        if let reason = Intelligence.shared.unavailableReason {
            intelligence.isEnabled = false
            intelligence.state = .off
            let note = NSMenuItem(title: "    \(reason)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        add(menu, "Answer questions", #selector(toggleAnswerQuestions),
            checked: Prefs.answerQuestions)
        add(menu, "Play sounds", #selector(toggleSounds), checked: Prefs.playSounds)
        add(menu, "Open at login", #selector(toggleLoginItem), checked: loginItemEnabled)

        menu.addItem(.separator())
        add(menu, "Clap Monitor…", #selector(showMonitor))
        add(menu, "Preview the HUD", #selector(previewHUD))
        add(menu, "Test the trigger", #selector(testTrigger))

        if SpeechListener.authorization != .authorized {
            menu.addItem(.separator())
            add(menu, "Speech recognition is off — open Settings", #selector(openSpeechSettings))
        }
        if !engine.micAuthorized {
            add(menu, "Microphone is off — open Settings", #selector(openMicSettings))
        }
        if Prefs.gestures, HandTracker.authorization == .denied {
            add(menu, "Camera is off — open Settings", #selector(openCameraSettings))
        }
        if Prefs.gestures, HandTracker.authorized, !Spaces.canSwitchDesktops {
            add(menu, "Desktop switching needs Accessibility — grant it",
                #selector(openAccessibilitySettings))
        }

        menu.addItem(.separator())
        add(menu, "Quit Jarvis", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     checked: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let checked { item.state = checked ? .on : .off }
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Prefs.enabled.toggle()
        if Prefs.enabled {
            if engine.micAuthorized {
                engine.start()
            } else {
                engine.requestPermissions { [weak self] granted in
                    granted ? self?.engine.start() : self?.promptForMicrophone()
                }
            }
        } else {
            engine.stop()
        }
        // Paused means paused: hand the combination back to whatever else wants it.
        Prefs.enabled ? applyTriggerShortcut() : TriggerHotKey.shared.unregister()
    }

    @objc private func pickSensitivity(_ sender: NSMenuItem) {
        guard let level = Sensitivity(rawValue: sender.tag) else { return }
        Prefs.sensitivity = level
        engine.applySensitivity()
    }

    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let shortcut = TriggerShortcut(rawValue: sender.tag) else { return }
        Prefs.triggerShortcut = shortcut
        applyTriggerShortcut()
    }

    /// A global hot key is registered for as long as Jarvis is enabled, so it
    /// really is taken away from every other app — worth saying out loud in the
    /// log rather than leaving you to wonder where \u{2318}J went.
    private func applyTriggerShortcut() {
        let shortcut = Prefs.triggerShortcut
        let ok = TriggerHotKey.shared.apply(shortcut)
        guard shortcut != .off else { return }
        if !ok { showError("Couldn't register \(shortcut.title) — another app already owns it. Pick a different keyboard trigger from the Jarvis menu.") }
    }

    @objc private func toggleSpeakReply() { Prefs.speakReply.toggle() }
    @objc private func toggleSounds() { Prefs.playSounds.toggle() }
    @objc private func toggleReuseTabs() { Prefs.reuseTabs.toggle() }
    @objc private func toggleVoiceEffects() { Prefs.voiceEffects.toggle() }

    @objc private func pickReverb(_ sender: NSMenuItem) {
        Prefs.reverbAmount = sender.tag
        VoiceBox.shared.resetChain()
        VoiceBox.shared.speak("Room tone set, sir.")
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        let identifier = (sender.representedObject as? String) ?? ""
        Prefs.voiceIdentifier = identifier.isEmpty ? nil : identifier
        VoiceBox.shared.speak(Intelligence.cannedReplies.randomElement() ?? "Welcome home, sir.")
    }

    @objc private func previewVoice() {
        VoiceBox.shared.speak("Welcome home, sir. All systems are online.")
    }

    @objc func getVoices() {
        NSApp.activate(ignoringOtherApps: true)
        let groups = VoiceBox.grouped()
        let good = groups.premium.count + groups.enhanced.count

        let alert = NSAlert()
        if good > 0 {
            alert.messageText = "\(good) high-quality voice\(good == 1 ? "" : "s") installed"
            alert.informativeText = """
            They're listed under Voice \u{203A} Premium and Enhanced. Pick one there, \
            or leave it on "Best installed voice" and Jarvis uses the best automatically.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        alert.messageText = "Siri voices can't be used by apps"
        alert.informativeText = """
        Every voice visible to Jarvis is still the low-quality "compact" kind.

        If you downloaded something called "Siri Voice 1-5", that's the catch: \
        macOS reserves the Siri voices for Siri and VoiceOver, and does not make \
        them available to third-party apps. Nothing Jarvis can do about that.

        What you want is further down the same list, under the language headings. \
        In System Settings: Accessibility \u{203A} Spoken Content \u{203A} System Voice \u{203A} \
        Manage Voices, scroll past the Siri section to English (United Kingdom) \
        and pick a voice tagged Enhanced or Premium — Daniel, Oliver, Malcolm, \
        Jamie or Serena.

        Jarvis re-checks every time you open its menu, so a new voice shows up \
        as soon as the download finishes.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!
            NSWorkspace.shared.open(url)
        }
    }

    /// Why the trigger shortcut isn't bound, if it isn't.
    private func triggerNote() -> String? {
        guard Prefs.enabled else { return "Jarvis is paused — other apps have it back" }
        return TriggerHotKey.shared.conflicted
            ? "Another app already owns that combination" : nil
    }

    /// What's stopping gestures from working, if anything. Mission Control needs
    /// only the camera; the two swipes also need Accessibility, so a half-granted
    /// setup says so rather than silently doing one of the three.
    private func gestureNote() -> String? {
        switch HandTracker.authorization {
        case .authorized:
            return Spaces.canSwitchDesktops ? nil
                : "Mission Control only — desktop switching needs Accessibility"
        case .denied, .restricted:
            return "Camera access is off"
        default:
            return "Camera access hasn't been granted yet"
        }
    }

    @objc private func toggleGestures() {
        Prefs.gestures.toggle()
        guard Prefs.gestures, HandTracker.authorization == .notDetermined else { return }
        HandTracker.requestAccess { _ in }
    }

    @objc private func toggleModel() { Prefs.useModel.toggle() }
    @objc private func toggleAnswerQuestions() { Prefs.answerQuestions.toggle() }
    @objc private func useFahrenheit() { Prefs.useCelsius = false }
    @objc private func useCelsius() { Prefs.useCelsius = true }

    @objc private func toggleHUD() {
        Prefs.showHUD.toggle()
        if !Prefs.showHUD { HUDOverlay.shared.dismissNow() }
    }

    @objc func showCommands() {
        if commands == nil {
            commands = CommandsWindow()
            commands?.onTest = { [weak self] macro in self?.engine.run(macro) }
        }
        commands?.reload()
        NSApp.activate(ignoringOtherApps: true)
        commands?.showWindow(nil)
        commands?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func setLocation() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Weather location"
        alert.informativeText = """
        Leave this blank to use Location Services. Or enter a fixed latitude and \
        longitude as "37.77, -122.42" to skip location access entirely.
        """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if let lat = Prefs.manualLatitude, let lon = Prefs.manualLongitude {
            field.stringValue = "\(lat), \(lon)"
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 {
            Prefs.manualLatitude = parts[0]
            Prefs.manualLongitude = parts[1]
        } else {
            Prefs.manualLatitude = nil
            Prefs.manualLongitude = nil
        }
    }

    @objc private func showMonitor() {
        if monitor == nil {
            let window = MonitorWindow()
            window.onVisibilityChange = { [weak self] visible in
                self?.engine.wantsLevels = visible
                self?.engine.wantsPreview(visible)
            }
            window.onCameraCheck = { [weak self] on in self?.engine.setCameraCheck(on) }
            monitor = window
        }
        NSApp.activate(ignoringOtherApps: true)
        monitor?.showWindow(nil)
        monitor?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func testTrigger() { engine.fire() }
    @objc private func remoteTrigger() { engine.fire() }
    @objc private func remoteArm() { engine.arm() }
    @objc private func remoteCancel() { engine.cancel() }

    /// Ask a question directly, e.g. userInfo ["text": "how are you"].
    @objc private func remoteAsk(_ note: Notification) {
        guard let text = note.userInfo?["text"] as? String else { return }
        engine.ask(text)
    }

    /// Run a named command, e.g. userInfo ["command": "Reminder", "text": "buy milk"].
    @objc private func remoteRun(_ note: Notification) {
        guard let name = note.userInfo?["command"] as? String else { return }
        engine.run(named: name, text: note.userInfo?["text"] as? String)
    }

    @objc func previewHUD() {
        HUDOverlay.shared.preview(reply: Intelligence.cannedReplies.randomElement() ?? "Welcome home, sir.")
    }

    @objc private func openMicSettings() { openSettings("Privacy_Microphone") }
    @objc private func openSpeechSettings() { openSettings("Privacy_SpeechRecognition") }
    @objc private func openCameraSettings() { openSettings("Privacy_Camera") }
    /// Asks for Accessibility, rather than just pointing at where it lives.
    ///
    /// `AXIsProcessTrusted` — what `Spaces.canSwitchDesktops` reads — deliberately
    /// never prompts, and an app that only ever reads it never appears in the
    /// Accessibility list at all. Opening the pane would have left you hunting
    /// for the + button and the bundle by hand. Asking *with* the prompt puts
    /// Jarvis in the list and hands you the switch to flick.
    @objc private func openAccessibilitySettings() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return }
        // The prompt carries its own "Open System Settings" button, so there is
        // nothing more to do here — opening the pane as well would only put a
        // window behind the dialog asking about the same thing.
    }

    private func openSettings(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Login item

    private var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLoginItem() {
        do {
            if loginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Couldn't change the login item: \(error.localizedDescription)")
        }
    }

    // MARK: - Alerts

    private func promptForMicrophone() {
        showError("Jarvis needs microphone access to hear your claps. Turn it on in System Settings \u{203A} Privacy & Security \u{203A} Microphone, then re-enable Jarvis from its menu.")
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Jarvis"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
