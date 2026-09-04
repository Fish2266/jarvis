import AppKit
import UniformTypeIdentifiers

/// Master-detail editor for your commands. Edits save as you make them.
final class CommandsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {

    var onTest: ((Macro) -> Void)?

    private var macros: [Macro] = MacroStore.load()
    private let table = NSTableView()

    private let nameField = NSTextField()
    private let phrasesView = NSTextView()
    private let targetView = NSTextView()
    private let kindPopup = NSPopUpButton()
    private let profilePopup = NSPopUpButton()
    private let profileLabel = NSTextField(labelWithString: "Profile")
    private let chooseButton = NSButton()
    private let enabledCheck = NSButton()
    private let testButton = NSButton()
    private let hint = NSTextField(labelWithString: "")
    private var targetLabelText = NSTextField(labelWithString: "Target")

    private var profiles: [ChromeProfile] = []
    /// The row the detail fields currently belong to. Edits commit against this,
    /// not the live selection, so clicking another row saves to the right macro.
    private var editingIndex: Int?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Jarvis — Commands"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 460)
        window.maxSize = NSSize(width: 1400, height: 1200)
        window.center()
        self.init(window: window)
        window.delegate = self
        build()
        reload()
    }

    // MARK: - Layout

    /// A scrolling, wrapping text view — long phrase lists and long URLs stay
    /// fully readable instead of being truncated to one clipped line.
    private func makeTextBox(_ view: NSTextView, minHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true

        view.isRichText = false
        view.font = .systemFont(ofSize: 13)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 4, height: 5)
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        view.delegate = self
        scroll.documentView = view
        return scroll
    }

    private func build() {
        guard let content = window?.contentView else { return }
        profiles = Browser.chromeProfiles()

        // Left: the list.
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Command"
        nameColumn.width = 120
        table.addTableColumn(nameColumn)

        let doesColumn = NSTableColumn(identifier: .init("does"))
        doesColumn.title = "Does"
        doesColumn.width = 130
        table.addTableColumn(doesColumn)

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset

        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(listScroll)

        let addRemove = NSSegmentedControl(
            labels: ["+", "−"], trackingMode: .momentary,
            target: self, action: #selector(addOrRemove(_:)))
        addRemove.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(addRemove)

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(resetButton)

        // Right: the detail form.
        nameField.delegate = self
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.placeholderString = "Minecraft"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let phrasesBox = makeTextBox(phrasesView, minHeight: 58)
        let targetBox = makeTextBox(targetView, minHeight: 46)

        kindPopup.addItems(withTitles: ActionKind.allCases.map(\.title))
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        kindPopup.translatesAutoresizingMaskIntoConstraints = false

        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profileLabel.alignment = .right
        profileLabel.translatesAutoresizingMaskIntoConstraints = false

        chooseButton.title = "Choose…"
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseApp)
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        enabledCheck.setButtonType(.switch)
        enabledCheck.title = "Enabled"
        enabledCheck.target = self
        enabledCheck.action = #selector(toggleEnabled)
        enabledCheck.translatesAutoresizingMaskIntoConstraints = false

        testButton.title = "Try it now"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testMacro)
        testButton.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 6
        hint.translatesAutoresizingMaskIntoConstraints = false
        // Without a wrap width, a wrapping label reports its full single-line
        // width as intrinsic — which forced the window wider than the screen.
        hint.preferredMaxLayoutWidth = 480
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hint.stringValue = """
        Phrases are separated by commas or new lines. A phrase can be just the target \
        ("the craft") — "open", "start", "start up", "launch", "fire up" and friends all \
        work in front of it. Or make it a whole catchphrase ("wake up daddy's home") and \
        say it on its own. Websites can open in a specific Chrome profile.
        """

        for view in [nameField, phrasesBox, targetBox, kindPopup, profilePopup,
                     profileLabel, chooseButton, enabledCheck, testButton, hint] {
            content.addSubview(view)
        }

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(field)
            return field
        }
        let nameLabel = label("Name")
        let saysLabel = label("Says")
        let actionLabel = label("Action")
        let targetLabel = label("Target")
        targetLabelText = targetLabel

        let labelWidth: CGFloat = 62
        let gutter: CGFloat = 10
        // Fields run to the window edge and grow with it — that, plus wrapping,
        // is what stops long values from being cut off.
        func fieldLeading(_ view: NSView) -> NSLayoutConstraint {
            view.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: gutter)
        }
        func fieldTrailing(_ view: NSView) -> NSLayoutConstraint {
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
        }

        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            listScroll.widthAnchor.constraint(equalToConstant: 258),
            listScroll.bottomAnchor.constraint(equalTo: addRemove.topAnchor, constant: -8),

            addRemove.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            addRemove.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            resetButton.leadingAnchor.constraint(equalTo: addRemove.trailingAnchor, constant: 8),
            resetButton.centerYAnchor.constraint(equalTo: addRemove.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 20),
            nameLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            nameLabel.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),

            nameField.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            fieldLeading(nameField), fieldTrailing(nameField),

            saysLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            saysLabel.topAnchor.constraint(equalTo: phrasesBox.topAnchor, constant: 3),
            phrasesBox.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            fieldLeading(phrasesBox), fieldTrailing(phrasesBox),

            actionLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            actionLabel.centerYAnchor.constraint(equalTo: kindPopup.centerYAnchor),
            kindPopup.topAnchor.constraint(equalTo: phrasesBox.bottomAnchor, constant: 12),
            fieldLeading(kindPopup),

            profileLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            profileLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            profileLabel.centerYAnchor.constraint(equalTo: profilePopup.centerYAnchor),
            profilePopup.topAnchor.constraint(equalTo: kindPopup.bottomAnchor, constant: 10),
            fieldLeading(profilePopup),
            profilePopup.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            targetLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            targetLabel.topAnchor.constraint(equalTo: targetBox.topAnchor, constant: 3),
            targetBox.topAnchor.constraint(equalTo: profilePopup.bottomAnchor, constant: 12),
            fieldLeading(targetBox),
            targetBox.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -8),
            chooseButton.topAnchor.constraint(equalTo: targetBox.topAnchor),
            fieldTrailing(chooseButton),

            enabledCheck.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            enabledCheck.topAnchor.constraint(equalTo: targetBox.bottomAnchor, constant: 12),
            testButton.leadingAnchor.constraint(equalTo: enabledCheck.trailingAnchor, constant: 16),
            testButton.centerYAnchor.constraint(equalTo: enabledCheck.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            fieldTrailing(hint),
            hint.topAnchor.constraint(equalTo: enabledCheck.bottomAnchor, constant: 14),
            hint.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
    }

    /// What the Target box holds for each action, or "" for the kinds that
    /// don't have one. Also decides whether the box is editable at all, so
    /// there is one answer rather than two lists that can drift apart.
    static func targetLabel(for kind: ActionKind) -> String {
        switch kind {
        case .app:       return "App"
        case .url:       return "URL"
        case .search:    return "Engine"
        case .reminder:  return "List"
        case .weather, .forecast, .reminders, .agenda, .timer, .volume,
             .media, .window, .awake, .clipboard, .lock, .sleep:
            return ""
        }
    }

    /// The guidance changes with the action, because the phrase means something
    /// different for a reminder than for an app.
    private func applyHint(for kind: ActionKind) {
        switch kind {
        case .search:
            hint.stringValue = "Phrases here are prefixes — say the phrase, then what you're "
                + "looking for. Engine is the search URL the words are added to; leave it "
                + "empty for Google, or paste another site's search URL to point this "
                + "command at it. Put %s in the URL if the words don't go on the end."
        case .timer:
            hint.stringValue = "One timer at a time. Say a length to start it (\"set a timer "
                + "for ten minutes\"), \"cancel the timer\" to stop it, or \"how long is left\" "
                + "to check. Starting a second timer replaces the first."
        case .volume:
            hint.stringValue = "The words decide what happens: up, down, louder, quieter, "
                + "mute, unmute, or a number — \"set the volume to forty\". Say nothing "
                + "specific and it reports where the volume is now."
        case .media:
            hint.stringValue = "Sends the media key to whatever is playing — Music, Spotify, "
                + "a video in a tab. \"Pause\" is a toggle, so it starts a paused track too. "
                + "Needs Accessibility, the same grant the desktop gestures use."
        case .window:
            hint.stringValue = "Moves the window in front of you: halves, quarters, "
                + "maximised, centred, or full screen. The words decide which — \"snap "
                + "left\", \"top right\", \"fill the screen\". Needs Accessibility, the "
                + "same grant the desktop gestures use."
        case .awake:
            hint.stringValue = "Stops the Mac dozing off. Say a length to hold it for a "
                + "while (\"stay awake for two hours\"), or nothing to hold it until you "
                + "say \"let it sleep\". The assertion is released when Jarvis quits."
        case .clipboard:
            hint.stringValue = "Phrases here are prefixes — say the phrase, then whatever "
                + "you want kept. It goes straight onto the clipboard, ready to paste. "
                + "Ask \"what's on my clipboard\" to hear it back."
        case .reminders, .agenda:
            hint.stringValue = "Reads out what's there — the first few, then how many more. "
                + "Read-only: no command in Jarvis can delete a reminder or change an event."
        case .lock:
            hint.stringValue = "Say one of these phrases on its own and the screen locks. "
                + "Matching is near-exact on purpose, so a sentence that merely contains "
                + "\"lock\" won't fire it. This can only lock — never shut down or restart."
        case .sleep:
            hint.stringValue = "Say one of these phrases on its own and the Mac sleeps. "
                + "Matching is near-exact on purpose, so an unrelated sentence containing "
                + "\"sleep\" won't trigger it. This can only sleep — never shut down or restart."
        case .reminder:
            hint.stringValue = "Phrases here are prefixes. Say the phrase, then whatever the "
                + "reminder is: \"remind me to call mom tomorrow at five\" becomes a reminder "
                + "titled \"call mom\", due tomorrow at 5. Leave List empty for your default list."
        case .url:
            hint.stringValue = "Phrases are separated by commas or new lines, and pair with any "
                + "verb. Pick a Chrome profile to pin this site to one account; you can also say "
                + "it out loud, as in \"open gmail on personal\"."
        default:
            hint.stringValue = "Phrases are separated by commas or new lines. A phrase can be "
                + "just the target (\"the craft\") and pair with any verb, or a whole catchphrase "
                + "(\"wake up daddy's home\") you say on its own."
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { macros.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let macro = macros[row]
        let text: String
        if tableColumn?.identifier.rawValue == "name" {
            text = macro.name
        } else {
            switch macro.kind {
            case .app: text = "App"
            case .url, .search:
                let base = macro.kind == .url ? "Website" : "Search"
                if let profile = Browser.profileName(for: macro.chromeProfile) {
                    text = "\(base) · \(profile)"
                } else {
                    text = base
                }
            case .weather:   text = "Weather"
            case .forecast:  text = "Forecast"
            case .reminder:  text = "Reminder"
            case .reminders: text = "Reminders"
            case .agenda:    text = "Calendar"
            case .timer:     text = "Timer"
            case .volume:    text = "Volume"
            case .media:     text = "Playback"
            case .window:    text = "Window"
            case .awake:     text = "Stay awake"
            case .clipboard: text = "Clipboard"
            case .lock:      text = "Lock"
            case .sleep:     text = "Sleep"
            }
        }
        let field = NSTextField(labelWithString: text)
        field.textColor = macro.enabled ? .labelColor : .tertiaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = "\(macro.name) — \(macro.subtitle)"
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        commit()
        populate()
    }

    // MARK: - Detail

    private func populate() {
        let row = table.selectedRow
        let index = (row >= 0 && row < macros.count) ? row : nil
        editingIndex = index

        guard let index else {
            let controls: [NSControl] = [nameField, kindPopup, profilePopup,
                                         chooseButton, enabledCheck, testButton]
            controls.forEach { $0.isEnabled = false }
            phrasesView.isEditable = false
            targetView.isEditable = false
            nameField.stringValue = ""
            phrasesView.string = ""
            targetView.string = ""
            return
        }
        let controls: [NSControl] = [nameField, kindPopup, enabledCheck, testButton]
        controls.forEach { $0.isEnabled = true }
        phrasesView.isEditable = true

        let macro = macros[index]
        nameField.stringValue = macro.name
        phrasesView.string = macro.phrases.joined(separator: ", ")
        targetView.string = macro.target
        kindPopup.selectItem(at: ActionKind.allCases.firstIndex(of: macro.kind) ?? 0)
        enabledCheck.state = macro.enabled ? .on : .off

        rebuildProfilePopup(selecting: macro.chromeProfile)

        // A profile only means anything for the kinds that open a page.
        let opensAPage = macro.kind == .url || macro.kind == .search
        // The label decides it: a kind with no Target label has no Target.
        let targetLabel = Self.targetLabel(for: macro.kind)
        targetView.isEditable = !targetLabel.isEmpty
        chooseButton.isEnabled = macro.kind == .app
        chooseButton.isHidden = macro.kind != .app
        profilePopup.isEnabled = opensAPage && !profiles.isEmpty
        profilePopup.isHidden = !opensAPage
        profileLabel.isHidden = !opensAPage

        targetLabelText.stringValue = targetLabel
        applyHint(for: macro.kind)
    }

    private func rebuildProfilePopup(selecting directory: String?) {
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: "Default browser")
        for profile in profiles {
            profilePopup.addItem(withTitle: profile.label)
        }
        if let directory, let index = profiles.firstIndex(where: { $0.directory == directory }) {
            profilePopup.selectItem(at: index + 1)
        } else {
            profilePopup.selectItem(at: 0)
        }
    }

    private func commit() {
        guard let index = editingIndex, index < macros.count else { return }
        var macro = macros[index]
        macro.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        // Commas or new lines both separate phrases.
        macro.phrases = phrasesView.string
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        macro.target = targetView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        macro.kind = ActionKind.allCases[max(0, kindPopup.indexOfSelectedItem)]
        macro.enabled = enabledCheck.state == .on

        let profileIndex = profilePopup.indexOfSelectedItem - 1
        macro.chromeProfile = (macro.kind == .url && profileIndex >= 0 && profileIndex < profiles.count)
            ? profiles[profileIndex].directory : nil

        guard macro != macros[index] else { return }
        macros[index] = macro
        MacroStore.save(macros)

        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < macros.count {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }
    func textDidEndEditing(_ notification: Notification) { commit() }

    @objc private func kindChanged() { commit(); populate() }
    @objc private func profileChanged() { commit() }
    @objc private func toggleEnabled() { commit() }

    @objc private func testMacro() {
        commit()
        guard let index = editingIndex, index < macros.count else { return }
        onTest?(macros[index])
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        targetView.string = url.path
        let appName = url.deletingPathExtension().lastPathComponent
        if nameField.stringValue.isEmpty || nameField.stringValue == "New Command" {
            nameField.stringValue = appName
            if phrasesView.string.isEmpty { phrasesView.string = appName.lowercased() }
        }
        commit()
    }

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        commit()
        if sender.selectedSegment == 0 {
            macros.append(Macro(name: "New Command", phrases: [], kind: .app, target: ""))
            MacroStore.save(macros)
            table.reloadData()
            table.selectRowIndexes([macros.count - 1], byExtendingSelection: false)
            populate()
            window?.makeFirstResponder(nameField)
        } else if let index = editingIndex, index < macros.count {
            macros.remove(at: index)
            editingIndex = nil
            MacroStore.save(macros)
            table.reloadData()
            populate()
        }
    }

    @objc private func resetDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset commands?"
        alert.informativeText = "This replaces your commands with the built-in defaults."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        editingIndex = nil
        macros = MacroStore.resetToDefaults()
        reload()
    }

    func windowDidResize(_ notification: Notification) {
        let width = hint.frame.width
        if width > 100, abs(hint.preferredMaxLayoutWidth - width) > 1 {
            hint.preferredMaxLayoutWidth = width
            hint.invalidateIntrinsicContentSize()
        }
    }

    func reload() {
        editingIndex = nil
        macros = MacroStore.load()
        profiles = Browser.chromeProfiles()
        table.reloadData()
        if !macros.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        populate()
    }
}
