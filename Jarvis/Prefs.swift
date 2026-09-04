import Foundation
import Carbon.HIToolbox

enum Sensitivity: Int, CaseIterable {
    case low = 0, medium = 1, high = 2

    var title: String {
        switch self {
        case .low: return "Low (noisy room)"
        case .medium: return "Medium"
        case .high: return "High (quiet room)"
        }
    }

    /// Thresholds are measured on the high-pass-filtered RMS of a ~5 ms frame.
    var config: ClapConfig {
        switch self {
        case .low:    return ClapConfig(absoluteThreshold: 0.090, attackRatio: 12)
        case .medium: return ClapConfig(absoluteThreshold: 0.045, attackRatio: 8)
        case .high:   return ClapConfig(absoluteThreshold: 0.020, attackRatio: 6)
        }
    }
}

/// What the trigger shortcut is bound to.
///
/// A global hot key really is global: while it's registered, the combination
/// belongs to Jarvis and no other app will see it. ⌘J is what you'd reach for
/// first and it's the default, but it's also Finder's View Options and Xcode's
/// jump bar — hence the alternatives and the off switch.
enum TriggerShortcut: Int, CaseIterable {
    case off = 0
    case commandJ = 1
    case optionCommandJ = 2
    case controlCommandJ = 3
    case optionSpace = 4

    var title: String {
        switch self {
        case .off:              return "Off (double clap only)"
        case .commandJ:         return "\u{2318}J"
        case .optionCommandJ:   return "\u{2325}\u{2318}J"
        case .controlCommandJ:  return "\u{2303}\u{2318}J"
        case .optionSpace:      return "\u{2325}Space"
        }
    }

    /// Combinations another app is likely to want back.
    var note: String? {
        switch self {
        case .commandJ:  return "also Finder's View Options and Xcode's jump bar"
        case .optionSpace: return "also Spotlight, on some setups"
        default: return nil
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .off: return nil
        case .commandJ, .optionCommandJ, .controlCommandJ: return UInt32(kVK_ANSI_J)
        case .optionSpace: return UInt32(kVK_Space)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .off:              return 0
        case .commandJ:         return UInt32(cmdKey)
        case .optionCommandJ:   return UInt32(optionKey | cmdKey)
        case .controlCommandJ:  return UInt32(controlKey | cmdKey)
        case .optionSpace:      return UInt32(optionKey)
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let sensitivity = "sensitivity"
        static let speakReply = "speakReply"
        static let sounds = "playSounds"
        static let hud = "showHUD"
        static let useModel = "useAppleIntelligence"
        static let latitude = "manualLatitude"
        static let longitude = "manualLongitude"
        static let celsius = "useCelsius"
        static let reuseTabs = "reuseTabs"
        static let voice = "voiceIdentifier"
        static let voiceEffects = "voiceEffects"
        static let reverb = "reverbAmount"
        static let voiceNudge = "voiceNudgeShown"
        static let answerQuestions = "answerQuestions"
        static let gestures = "handGestures"
        static let trigger = "triggerShortcut"
        static let dim = "dimScreen"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.enabled: true,
            Key.sensitivity: Sensitivity.medium.rawValue,
            Key.speakReply: true,
            Key.sounds: true,
            Key.hud: true,
            Key.useModel: true,
            Key.celsius: false,
            Key.reuseTabs: true,
            Key.voiceEffects: true,
            Key.answerQuestions: true,
            Key.gestures: true,
            Key.trigger: TriggerShortcut.commandJ.rawValue,
            Key.reverb: 0,
            Key.dim: true,
        ])
    }

    static var enabled: Bool {
        get { d.bool(forKey: Key.enabled) }
        set { d.set(newValue, forKey: Key.enabled) }
    }

    static var sensitivity: Sensitivity {
        get { Sensitivity(rawValue: d.integer(forKey: Key.sensitivity)) ?? .medium }
        set { d.set(newValue.rawValue, forKey: Key.sensitivity) }
    }



    static var speakReply: Bool {
        get { d.bool(forKey: Key.speakReply) }
        set { d.set(newValue, forKey: Key.speakReply) }
    }


    static var playSounds: Bool {
        get { d.bool(forKey: Key.sounds) }
        set { d.set(newValue, forKey: Key.sounds) }
    }

    static var showHUD: Bool {
        get { d.bool(forKey: Key.hud) }
        set { d.set(newValue, forKey: Key.hud) }
    }

    /// Governs both the tier-2 fallback and the generated spoken reply.
    static var useModel: Bool {
        get { d.bool(forKey: Key.useModel) }
        set { d.set(newValue, forKey: Key.useModel) }
    }

    /// Jump to an already-open tab instead of opening another copy.
    static var reuseTabs: Bool {
        get { d.bool(forKey: Key.reuseTabs) }
        set { d.set(newValue, forKey: Key.reuseTabs) }
    }

    /// Chosen speech voice. nil means "use the best one installed".
    static var voiceIdentifier: String? {
        get { d.string(forKey: Key.voice) }
        set { newValue == nil ? d.removeObject(forKey: Key.voice)
                              : d.set(newValue!, forKey: Key.voice) }
    }

    /// Run speech through the local EQ and reverb chain.
    static var voiceEffects: Bool {
        get { d.bool(forKey: Key.voiceEffects) }
        set { d.set(newValue, forKey: Key.voiceEffects) }
    }

    /// Reverb wet/dry mix, 0-100. Small: a hint of room, not an echo.
    static var reverbAmount: Int {
        get { d.integer(forKey: Key.reverb) }
        set { d.set(max(0, min(100, newValue)), forKey: Key.reverb) }
    }

    /// Whether the "your voices are all low quality" note has been shown.
    static var voiceNudgeShown: Bool {
        get { d.bool(forKey: Key.voiceNudge) }
        set { d.set(newValue, forKey: Key.voiceNudge) }
    }

    /// Send anything that sounds like a question to Apple Intelligence.
    static var answerQuestions: Bool {
        get { d.bool(forKey: Key.answerQuestions) }
        set { d.set(newValue, forKey: Key.answerQuestions) }
    }

    /// Watch for hand gestures after a double clap.
    ///
    /// The camera only ever runs inside that window — this is the switch for
    /// whether it runs at all, not for whether it runs now.
    static var gestures: Bool {
        get { d.bool(forKey: Key.gestures) }
        set { d.set(newValue, forKey: Key.gestures) }
    }

    /// Global shortcut that arms Jarvis, alongside the double clap.
    static var triggerShortcut: TriggerShortcut {
        get { TriggerShortcut(rawValue: d.integer(forKey: Key.trigger)) ?? .commandJ }
        set { d.set(newValue.rawValue, forKey: Key.trigger) }
    }

    /// Darken the desktop behind the reticle.
    ///
    /// On by default, because the cyan is hard to read over a bright window.
    /// Off for anyone who would rather keep looking at their work while they
    /// talk — the one part of the HUD that covers anything.
    static var dimScreen: Bool {
        get { d.bool(forKey: Key.dim) }
        set { d.set(newValue, forKey: Key.dim) }
    }

    static var useCelsius: Bool {
        get { d.bool(forKey: Key.celsius) }
        set { d.set(newValue, forKey: Key.celsius) }
    }

    /// Set these to skip Location Services entirely for weather.
    static var manualLatitude: Double? {
        get { d.object(forKey: Key.latitude) as? Double }
        set { newValue == nil ? d.removeObject(forKey: Key.latitude)
                              : d.set(newValue!, forKey: Key.latitude) }
    }

    static var manualLongitude: Double? {
        get { d.object(forKey: Key.longitude) as? Double }
        set { newValue == nil ? d.removeObject(forKey: Key.longitude)
                              : d.set(newValue!, forKey: Key.longitude) }
    }
}
