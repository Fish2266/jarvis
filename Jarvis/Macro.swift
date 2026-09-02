import Foundation

enum ActionKind: String, Codable, CaseIterable {
    case app, url, weather, reminder, sleep

    var title: String {
        switch self {
        case .app: return "Open an app"
        case .url: return "Open a website"
        case .weather: return "Report the weather"
        case .reminder: return "Add a reminder"
        case .sleep: return "Put the Mac to sleep"
        }
    }

    /// Kinds whose phrase is a prefix and whose remaining words are the content.
    var capturesText: Bool { self == .reminder }

    /// Kinds that must match a phrase almost exactly rather than by containment.
    ///
    /// Sleeping the Mac mid-sentence would be miserable, and ordinary fuzzy
    /// matching would fire on "how do i sleep better" because it contains
    /// "sleep". These only run when you say the phrase and little else.
    var requiresExactPhrase: Bool { self == .sleep }

    /// Kinds that speak for themselves, so the usual generated reply is skipped.
    var handlesOwnReply: Bool { self == .sleep }

    /// Kinds with a window that "bring it over" could move to this desktop.
    /// The rest ignore the request and just do their usual thing, so "gimme
    /// the weather" still reports the weather rather than falling flat.
    var canBeBrought: Bool { self == .app || self == .url }
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
        case .app, .url:
            guard let profile = Browser.profileName(for: chromeProfile) else { return "Opening \(name)" }
            return "Opening \(name) · \(profile)"
        case .weather:   return "Checking the weather"
        case .reminder:  return "Adding a reminder"
        case .sleep:     return "Going to sleep"
        }
    }

    var subtitle: String {
        switch kind {
        case .app:     return (target as NSString).lastPathComponent
        case .url:
            guard let profile = Browser.profileName(for: chromeProfile) else { return target }
            return "\(target) · \(profile)"
        case .weather: return "Local conditions"
        case .reminder: return target.isEmpty ? "Default list" : target
        case .sleep: return "Sleep only — never shut down or restart"
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
                          "new window", "the browser", "browser"],
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
        return macros
    }
}

enum MacroStore {
    private static let key = "macros"

    static func load() -> [Macro] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let macros = try? JSONDecoder().decode([Macro].self, from: data),
              !macros.isEmpty
        else {
            let seeded = Macro.seeded()
            save(seeded)
            return seeded
        }
        return macros
    }

    static func save(_ macros: [Macro]) {
        guard let data = try? JSONEncoder().encode(macros) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .macrosChanged, object: nil)
    }

    static func resetToDefaults() -> [Macro] {
        let seeded = Macro.seeded()
        save(seeded)
        return seeded
    }
}

extension Notification.Name {
    static let macrosChanged = Notification.Name("JarvisMacrosChanged")
}
