import AudioToolbox
import CoreAudio

/// The output volume, read and written through CoreAudio.
///
/// Deliberately not AppleScript's `set volume`. That would mean compiling and
/// running a script for a number, and — more to the point — it goes through
/// Apple Events, which is the one thing in this app that needs a permission
/// prompt. This talks to the audio device directly: in process, no permission,
/// and a get costs a few microseconds.
///
/// Every call degrades to "did nothing" rather than trapping. A Mac with no
/// output device, or one whose driver doesn't publish a volume control (some
/// USB interfaces and most HDMI outputs hand volume to the display), reports
/// `nil` and the caller says so out loud instead of pretending it worked.
enum SystemAudio {

    /// The device the system is playing through right now. Read every time
    /// rather than cached — plugging in headphones changes the answer, and the
    /// lookup is a single property read.
    private static func outputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// 0…1, or nil if this output has no volume control we can reach.
    static func volume() -> Float? {
        guard let device = outputDevice() else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return min(1, max(0, value))
    }

    /// Sets the volume, clamped to 0…1. Setting a level also unmutes: asking
    /// for "volume to forty" while muted and getting silence back would look
    /// exactly like the command not working.
    @discardableResult
    static func setVolume(_ level: Float) -> Bool {
        guard let device = outputDevice() else { return false }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }

        var value = min(1, max(0, level))
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        guard status == noErr else { return false }
        if value > 0 { setMuted(false) }
        return true
    }

    static func isMuted() -> Bool? {
        guard let device = outputDevice() else { return nil }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = outputDevice() else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Some outputs publish no mute control at all — HDMI and a good many USB
    /// interfaces hand both volume and mute to the hardware. Muting those means
    /// remembering where the level was and putting it back.
    private static var levelBeforeMute: Float?

    static var canMuteDirectly: Bool { isMuted() != nil }

    // MARK: - What a spoken command asks for

    enum Change: Equatable {
        case up(Int)            // percentage points
        case down(Int)
        case set(Int)           // absolute percent
        case mute
        case unmute
        case toggleMute
        case report             // "how loud is it"
    }

    /// The step "turn it up" moves by. A tenth is what the volume keys do.
    static let step = 10

    /// Reads a volume command out of the whole sentence.
    ///
    /// Whole-token runs rather than substrings, for the same reason the media
    /// keys use them: "up" is a substring of "upload", and the difference
    /// between hearing a command and hearing a word that contains one is the
    /// whole difference between this working and being a nuisance.
    static func change(for words: String) -> Change? {
        let normalized = PhraseMatcher.normalize(words)
        let haystack = PhraseMatcher.Haystack(normalized)
        guard haystack.wordCount > 0 else { return nil }
        func said(_ phrase: String) -> Bool {
            PhraseMatcher.containsTokenRun(haystack, phrase)
        }

        // An explicit level wins over everything: "volume up to 40" is a
        // request for forty, not a request to go up.
        if let percent = spokenLevel(in: normalized) { return .set(percent) }

        if said("unmute") || said("sound on") || said("turn the sound on")
            || said("volume on") { return .unmute }
        if said("mute") || said("silence") || said("shut up") || said("be quiet")
            || said("sound off") || said("quiet") { return .mute }

        if said("all the way up") || said("max") || said("maximum") || said("full")
            || said("full blast") { return .set(100) }

        if said("up") || said("louder") || said("higher") || said("raise")
            || said("increase") || said("turn it up") { return .up(step) }
        if said("down") || said("quieter") || said("lower") || said("softer")
            || said("decrease") || said("reduce") { return .down(step) }

        if said("how loud") || said("what volume") || said("volume level")
            || said("check the volume") { return .report }
        return nil
    }

    /// The number in "set the volume to forty" or "volume 40 percent".
    ///
    /// Words as well as digits, because a recogniser writes small numbers out.
    /// Only 0…100 counts — "volume to 400" is a misheard sentence, not a
    /// request, and clamping it to full blast is the wrong kind of helpful.
    static func spokenLevel(in normalized: String) -> Int? {
        let words = normalized.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            let value: Int?
            if let digits = Int(word) {
                value = digits
            } else if let spelled = Calc.numberWords[word], spelled > 0 {
                // "twenty five" arrives as two words; add the units digit when
                // a round ten is followed by one.
                if spelled % 10 == 0, spelled >= 20, index + 1 < words.count,
                   let units = Calc.numberWords[words[index + 1]], units < 10, units > 0 {
                    value = spelled + units
                } else {
                    value = spelled
                }
            } else {
                value = nil
            }
            guard let value, (0...100).contains(value) else { continue }

            // A bare number is only a level when something in the sentence
            // says so — otherwise "play track 5" would set the volume to five.
            let before = index > 0 ? words[index - 1] : ""
            let after = index + 1 < words.count ? words[index + 1] : ""
            let anchored = ["to", "at", "on"].contains(before)
                || ["percent"].contains(after)
                || (index > 1 && ["volume", "sound"].contains(words[index - 2]))
            if anchored { return value }
        }
        return nil
    }

    /// Applies a change and returns the line to say, or nil if the output
    /// can't be driven from here.
    static func apply(_ change: Change) -> String? {
        switch change {
        case .report:
            guard let level = volume() else { return nil }
            if isMuted() == true { return "Muted, sir." }
            return "Volume is at \(percent(level)) percent, sir."

        case .mute, .unmute, .toggleMute:
            let wantMuted: Bool
            switch change {
            case .mute: wantMuted = true
            case .unmute: wantMuted = false
            default: wantMuted = !(isMuted() ?? (volume() == 0))
            }
            if canMuteDirectly {
                guard setMuted(wantMuted) else { return nil }
            } else {
                // No mute control on this device — fall back to the level,
                // remembering where it was so unmuting restores it.
                if wantMuted {
                    let current = volume() ?? 0
                    if current > 0 { levelBeforeMute = current }
                    guard setVolume(0) else { return nil }
                } else {
                    let restore = levelBeforeMute ?? 0.4
                    levelBeforeMute = nil
                    guard setVolume(restore) else { return nil }
                }
            }
            return wantMuted ? "Muted, sir." : "Sound is back, sir."

        case .up(let amount):
            guard let current = volume() else { return nil }
            return set(percent: percent(current) + amount)

        case .down(let amount):
            guard let current = volume() else { return nil }
            return set(percent: percent(current) - amount)

        case .set(let percent):
            return set(percent: percent)
        }
    }

    private static func set(percent: Int) -> String? {
        let clamped = min(100, max(0, percent))
        guard setVolume(Float(clamped) / 100) else { return nil }
        if clamped == 0 { return "Silence, sir." }
        return "Volume at \(clamped) percent, sir."
    }

    static func percent(_ level: Float) -> Int { Int((level * 100).rounded()) }
}
