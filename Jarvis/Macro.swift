import Foundation

/// What a command does.
///
/// The order here is the order of the Action menu in the editor, so it runs
/// from the things most commands are (open something) to the things few are
/// (sleep the Mac). Raw values are stored in your preferences and must never
/// change; new cases can be added freely, because a `Macro` written by an
/// older build simply doesn't mention them.
enum ActionKind: String, Codable, CaseIterable {
    case app, url, search
    case weather, forecast
    case reminder, reminders, agenda
    case timer, volume, media
    case window, awake, clipboard
    case lock, sleep

    var title: String {
        switch self {
        case .app:       return "Open an app"
        case .url:       return "Open a website"
        case .search:    return "Search the web"
        case .weather:   return "Report the weather"
        case .forecast:  return "Report tomorrow's forecast"
        case .reminder:  return "Add a reminder"
        case .reminders: return "Read out your reminders"
        case .agenda:    return "Read out your calendar"
        case .timer:     return "Set a timer"
        case .volume:    return "Change the volume"
        case .media:     return "Play, pause or skip"
        case .window:    return "Move the front window"
        case .awake:     return "Keep the Mac awake"
        case .clipboard: return "Copy what you say"
        case .lock:      return "Lock the screen"
        case .sleep:     return "Put the Mac to sleep"
        }
    }

    /// Kinds whose phrase is a prefix and whose remaining words are the content.
    ///
    /// These never reach the ordinary fuzzy matcher — the phrase has to be at
    /// the front and something has to follow it — so a kind belongs here only
    /// if the words after the phrase are the *point* of the command. A timer
    /// deliberately isn't one: "cancel the timer" has nothing after it to
    /// capture, and splitting timers across two mechanisms to get that would
    /// be two places to look when one of them is wrong.
    var capturesText: Bool { self == .reminder || self == .search || self == .clipboard }

    /// Kinds that must match a phrase almost exactly rather than by containment.
    ///
    /// Sleeping the Mac mid-sentence would be miserable, and ordinary fuzzy
    /// matching would fire on "how do i sleep better" because it contains
    /// "sleep". These only run when you say the phrase and little else.
    ///
    /// Locking the screen is here for the same reason and one more: "lock" is
    /// a common enough word that containment would fire it on "what's the lock
    /// screen shortcut".
    var requiresExactPhrase: Bool { self == .sleep || self == .lock }

    /// Kinds that speak for themselves, so the usual generated reply is skipped.
    ///
    /// Two reasons to be on this list. Sleep and lock take the screen away a
    /// moment later, so the line is said first and the action follows — a
    /// generated reply arriving half a second after the Mac locked would be
    /// talking to an empty room. The rest produce a *fact*: "volume at forty
    /// percent", "three reminders", "five minutes left". A model paraphrase of
    /// a fact is slower, occasionally wrong about the number, and no more
    /// charming for it — and without this they would say both lines, one over
    /// the other.
    var handlesOwnReply: Bool {
        switch self {
        case .sleep, .lock, .timer, .volume, .media, .reminders, .agenda,
             .window, .awake, .clipboard:
            return true
        case .app, .url, .search, .weather, .forecast, .reminder:
            return false
        }
    }

    /// Kinds that read the whole sentence rather than a captured tail.
    ///
    /// "turn it up", "next track" and "cancel the timer" are all one command
    /// each with the detail buried in the words, so the action is handed what
    /// you actually said and works it out.
    var readsSentence: Bool {
        switch self {
        case .timer, .volume, .media, .window, .awake: return true
        default: return false
        }
    }

    /// Kinds with a window that "bring it over" could move to this desktop.
    /// The rest ignore the request and just do their usual thing, so "gimme
    /// the weather" still reports the weather rather than falling flat.
    var canBeBrought: Bool { self == .app || self == .url || self == .search }

    /// Kinds "quit it" can act on. Only an app has a process to end — a
    /// website command names a page, not something running — and as with
    /// bringing, anything else ignores the request rather than failing.
    var canBeQuit: Bool { self == .app }

    /// Kinds that produce something to be read rather than an action to watch.
    ///
    /// These hand their result to the answer strip, which lingers and draws the
    /// voice under it, instead of the reticle's headline — a list of three
    /// reminders is a sentence, not a status.
    var answersAloud: Bool { self == .reminders || self == .agenda }
}

/// One user-programmable command.
struct Macro: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// What you actually say. Either a bare target ("chrome", "the craft") that
    /// pairs with any verb, or a whole catchphrase ("wake up daddy's home").
    var phrases: [String]
    var kind: ActionKind
    /// App path for `.app`, URL for `.url`, unused for `.weather`.
    var target: String
    var enabled: Bool = true
    /// Chrome profile directory ("Default", "Profile 1") for `.url` commands.
    /// nil means whatever your default browser does. Optional so macros saved
    /// before this existed still decode.
    var chromeProfile: String?

    /// What the HUD says while this runs — the action, never the transcript.
    var actionLabel: String {
        switch kind {
        case .app, .url, .search:
            let verb = kind == .search ? "Searching" : "Opening"
            let subject = kind == .search ? "the web" : name
            guard let profile = Browser.profileName(for: chromeProfile) else {
                return "\(verb) \(subject)"
            }
            return "\(verb) \(subject) · \(profile)"
        case .weather:   return "Checking the weather"
        case .forecast:  return "Checking tomorrow"
        case .reminder:  return "Adding a reminder"
        case .reminders: return "Checking your reminders"
        case .agenda:    return "Checking your calendar"
        case .timer:     return "Timer"
        case .volume:    return "Volume"
        case .media:     return "Playback"
        case .window:    return "Moving the window"
        case .awake:     return "Staying awake"
        case .clipboard: return "Copying"
        case .lock:      return "Locking up"
        case .sleep:     return "Going to sleep"
        }
    }

    var subtitle: String {
        switch kind {
        case .app:     return (target as NSString).lastPathComponent
        case .url, .search:
            let base = kind == .search && target.isEmpty ? "Google" : target
            guard let profile = Browser.profileName(for: chromeProfile) else { return base }
            return "\(base) · \(profile)"
        case .weather:   return "Local conditions"
        case .forecast:  return "Tomorrow, where you are"
        case .reminder:  return target.isEmpty ? "Default list" : target
        case .reminders: return "Read out, never changed"
        case .agenda:    return "Today, read out"
        case .timer:     return "One at a time"
        case .volume:    return "Up, down, mute, or a number"
        case .media:     return "Whatever is playing"
        case .window:    return "Halves, corners, full screen"
        case .awake:     return "For a while, or until you say"
        case .clipboard: return "Straight to the clipboard"
        case .lock:      return "Lock only — never shut down or restart"
        case .sleep:     return "Sleep only — never shut down or restart"
        }
    }
}

extension Macro {
    static func seeded() -> [Macro] {
        var macros: [Macro] = []

        if let claude = AppLauncher.claudeURL() {
            macros.append(Macro(
                name: "Claude",
                phrases: ["wake up daddys home", "daddys home", "claude"],
                kind: .app, target: claude.path))
        }
        macros.append(Macro(
            name: "Sleep",
            phrases: ["sleep", "go to sleep", "power down", "night night",
                      "good night", "goodnight", "go to bed", "time for bed",
                      "lights out", "nap time"],
            kind: .sleep, target: ""))
        macros.append(Macro(
            name: "Weather",
            phrases: ["the weather", "weather", "whats it like outside",
                      "hows it looking outside", "forecast"],
            kind: .weather, target: ""))
        // Whichever launcher is actually installed.
        let launchers = ["Prism Launcher", "MultiMC", "ATLauncher", "Minecraft"]
        if let launcher = launchers.lazy
            .compactMap({ name in AppIndex.shared.entries.first { $0.name == name } })
            .first {
            macros.append(Macro(
                name: "Minecraft",
                phrases: ["the craft", "minecraft", "prism", "prism launcher"],
                kind: .app, target: launcher.path))
        }
        if let chrome = Browser.chromeURL() {
            macros.append(Macro(
                name: "Chrome",
                phrases: ["chrome", "google chrome", "new tab", "a new tab",
                          "another tab", "new window", "another window",
                          "the browser", "browser"],
                kind: .app, target: chrome.path))
        }
        macros.append(Macro(
            name: "Reminder",
            phrases: ["remind me to", "remind me", "add a reminder to", "add a reminder",
                      "set a reminder to", "set a reminder", "new reminder", "remember to"],
            kind: .reminder, target: ""))
        macros.append(Macro(
            name: "Gmail",
            phrases: ["gmail", "my email", "email", "my mail"],
            kind: .url, target: "https://mail.google.com"))
        macros.append(contentsOf: added)
        return macros
    }

    /// Built-in commands newer than the first release.
    ///
    /// Kept apart from `seeded` because they have a second job: `MacroStore`
    /// hands them to anyone whose commands were saved before they existed, so
    /// a feature added today reaches a Mac that has been running Jarvis for
    /// months. Appending to `seeded` alone would have shipped every one of
    /// these to new installs only — the saved list is never re-seeded.
    static let added: [Macro] = [
        Macro(name: "Search",
              phrases: ["search for", "search the web for", "look up", "look for",
                        "google for", "search google for", "web search for",
                        "do a search for"],
              kind: .search, target: "https://www.google.com/search?q="),
        // Two phrases are deliberately absent, and both were bugs first.
        //
        // A bare "timer" is one typo from "time", and the coverage count gives
        // a single-word phrase full marks for a single fuzzy word — so *every
        // sentence containing "time"* fired the timer, "what time is it"
        // included, and the clock stopped answering. "The timer" is safe
        // because the second word has to be there too.
        //
        // "How much time is left" is one word from "how much space is left",
        // which is a question about the disk.
        // "Timer for ten minutes" is deliberately not here, and it is the one
        // phrasing that had to be given up. "Timer for" and "time for" are a
        // single character apart, so it fired on "time for a break" — and a
        // command that eats an ordinary sentence is worse than one that asks
        // for a slightly fuller phrasing. Say "set a timer for ten minutes",
        // or put the unit in front: "a ten minute timer".
        Macro(name: "Timer",
              phrases: ["set a timer", "start a timer", "cancel the timer",
                        "stop the timer", "how long is left",
                        "how long on the timer", "time left on the timer",
                        "minute timer", "second timer", "hour timer"],
              kind: .timer, target: ""),
        Macro(name: "Volume",
              phrases: ["volume", "turn it up", "turn it down", "turn the volume up",
                        "turn the volume down", "louder", "quieter", "mute", "unmute",
                        "shut up", "be quiet", "how loud is it"],
              kind: .volume, target: ""),
        // Deliberately no bare "play": it is already a verb meaning "open", so
        // "play minecraft" has to keep opening Minecraft. It costs nothing,
        // because the key macOS sends is a *toggle* — "pause it" starts a
        // paused track as readily as it stops a playing one.
        //
        // Nor a bare "pause" or "skip", for a different reason: each is one
        // typo from an ordinary word ("cause", "ship"), and the coverage count
        // gives a one-word phrase full marks for a single fuzzy word — so
        // "what's the cause of that" paused your music. Two words fixes it,
        // because the second has to be there as well.
        Macro(name: "Playback",
              phrases: ["pause it", "pause the music", "pause playback", "resume",
                        "unpause", "play pause", "next track", "previous track",
                        "next song", "previous song", "skip this", "skip the song",
                        "skip ahead", "last song"],
              kind: .media, target: ""),
        // Every phrase says "tomorrow", and that is deliberate. The Weather
        // command already answers to "forecast", and two commands a hair apart
        // in the matcher decide by array order rather than by what you meant —
        // so this one only answers to sentences the other cannot match at all.
        Macro(name: "Forecast",
              phrases: ["tomorrows forecast", "tomorrows weather", "hows tomorrow looking",
                        "whats tomorrow looking like", "whats tomorrow like",
                        "will it rain tomorrow", "the forecast for tomorrow",
                        "what about tomorrow"],
              kind: .forecast, target: ""),
        Macro(name: "My reminders",
              phrases: ["my reminders", "whats on my list", "what are my reminders",
                        "what do i have to do", "whats on my to do list",
                        "read my reminders"],
              kind: .reminders, target: ""),
        Macro(name: "My day",
              phrases: ["my day", "whats on today", "whats my day look like",
                        "whats on my calendar", "my calendar", "my schedule",
                        "whats my next meeting", "next meeting", "am i free"],
              kind: .agenda, target: ""),
        Macro(name: "Lock",
              phrases: ["lock the screen", "lock it up", "lock up", "lock my mac",
                        "lock the mac", "lock screen"],
              kind: .lock, target: ""),
        // Deliberately no bare "left" or "right" here, though the action
        // understands both. Those two words turn up in far too many sentences
        // to be a command on their own; the phrase has to say it is about a
        // window, and the action then reads which way out of the whole thing.
        Macro(name: "Window",
              phrases: ["snap left", "snap right", "left half", "right half",
                        "top half", "bottom half", "maximise", "maximize",
                        "fill the screen", "centre the window", "center the window",
                        "full screen", "move the window", "put it on the left",
                        "put it on the right"],
              kind: .window, target: ""),
        // Nothing here is mostly the word "sleep". "Dont sleep" is ten
        // characters of which five are "sleep", which was close enough to
        // "do i sleep" that "how do i sleep better" asked the Mac to stay
        // awake. The release phrases carry their own weight instead, and
        // "stop"/"cancel" anywhere in a sentence that matched a hold phrase
        // releases it too.
        Macro(name: "Stay awake",
              phrases: ["stay awake", "keep awake", "keep the mac awake",
                        "caffeinate", "dont let the mac sleep",
                        "stop staying awake", "stop keeping it awake",
                        "you can let it sleep now"],
              kind: .awake, target: ""),
        Macro(name: "Copy",
              phrases: ["copy that down", "copy this down", "note this down",
                        "copy down", "remember this", "put this on the clipboard"],
              kind: .clipboard, target: ""),
    ]
}

enum MacroStore {
    private static let key = "macros"
    private static let builtinsKey = "builtinsInstalled"

    /// How many of `Macro.added` this build knows about. Bumped whenever a new
    /// built-in is appended to that list.
    static var builtinCount: Int { Macro.added.count }

    static func load() -> [Macro] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let macros = decode(data),
              !macros.isEmpty
        else {
            let seeded = Macro.seeded()
            save(seeded)
            UserDefaults.standard.set(builtinCount, forKey: builtinsKey)
            return seeded
        }
        return installNewBuiltins(into: macros)
    }

    /// Decodes the saved list, and survives one bad entry.
    ///
    /// Decoding the array in one go means a single unreadable command — one
    /// written by a newer build with an action this one has never heard of —
    /// throws the *whole* list away, and `load` then quietly reseeds over
    /// everything you had written. Element by element, an unreadable command
    /// is skipped and the rest of your commands come back.
    static func decode(_ data: Data) -> [Macro]? {
        if let macros = try? JSONDecoder().decode([Macro].self, from: data) { return macros }
        guard let loose = try? JSONDecoder().decode([FailableMacro].self, from: data)
        else { return nil }
        let salvaged = loose.compactMap(\.macro)
        return salvaged.isEmpty ? nil : salvaged
    }

    /// A macro that decodes to nil instead of throwing, so one bad element in
    /// the array doesn't take the array with it.
    private struct FailableMacro: Decodable {
        let macro: Macro?
        init(from decoder: Decoder) throws {
            macro = try? Macro(from: decoder)
        }
    }

    /// Gives an existing installation the built-ins it has never been offered.
    ///
    /// Runs once per new built-in, keyed on how many have been installed rather
    /// than on their names — so a command you deliberately deleted stays
    /// deleted, and one added in a later version still arrives. Anything
    /// already present under the same name is skipped, so a hand-written
    /// "Timer" is never shadowed by the built-in one.
    private static func installNewBuiltins(into macros: [Macro]) -> [Macro] {
        let installed = UserDefaults.standard.integer(forKey: builtinsKey)
        guard installed < builtinCount else { return macros }

        let existing = Set(macros.map { PhraseMatcher.normalize($0.name) })
        let missing = Macro.added.dropFirst(installed)
            .filter { !existing.contains(PhraseMatcher.normalize($0.name)) }

        UserDefaults.standard.set(builtinCount, forKey: builtinsKey)
        guard !missing.isEmpty else { return macros }

        let combined = macros + missing
        save(combined)
        return combined
    }

    static func save(_ macros: [Macro]) {
        guard let data = try? JSONEncoder().encode(macros) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .macrosChanged, object: nil)
    }

    static func resetToDefaults() -> [Macro] {
        let seeded = Macro.seeded()
        save(seeded)
        UserDefaults.standard.set(builtinCount, forKey: builtinsKey)
        return seeded
    }
}

extension Notification.Name {
    static let macrosChanged = Notification.Name("JarvisMacrosChanged")
}
