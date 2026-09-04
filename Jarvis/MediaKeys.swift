import AppKit

/// Play/pause and track skipping, by synthesising the keys on the top row.
///
/// Deliberately not "tell Music to pause". Scripting a named app means an
/// Automation prompt for that app, a different prompt for Spotify, and nothing
/// at all for a video playing in a browser tab. The media keys go to whatever
/// macOS currently considers the *now playing* app, which is the same thing
/// pressing the key on the keyboard does — so one command covers Music,
/// Spotify, YouTube in a tab, and a podcast in Overcast, with no per-app
/// permission and no list to maintain.
///
/// The cost is that synthesising any key needs Accessibility, exactly as the
/// desktop-switching gestures do. Without it this reports false and the caller
/// says what is missing rather than silently doing nothing.
enum MediaKeys {

    /// `NX_KEYTYPE_*` from IOKit's `ev_keymap.h`. Not exposed to Swift, so the
    /// numbers are written out; they are ABI and have not moved in twenty years.
    enum Key: Int32 {
        case playPause = 16
        case next = 17
        case previous = 18
    }

    /// Whether a synthesised key can currently be delivered.
    ///
    /// The same grant the desktop gestures need — asked through `Spaces` so
    /// there is one answer to "is Jarvis trusted", not two that can disagree.
    static var available: Bool { Spaces.canSwitchDesktops }

    /// A media key is a `systemDefined` event with the key packed into `data1`,
    /// not an ordinary key code — there is no virtual key for "play".
    ///
    /// Both halves are sent. A down with no up leaves the key logically held,
    /// and the next press of the real key on the keyboard is then read as a
    /// repeat rather than a fresh press.
    @discardableResult
    static func press(_ key: Key) -> Bool {
        guard available else { return false }
        return post(key, down: true) && post(key, down: false)
    }

    private static func post(_ key: Key, down: Bool) -> Bool {
        let state = Int(down ? 0xA00 : 0xB00)
        let data1 = Int(key.rawValue) << 16 | state
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1),
            let cg = event.cgEvent
        else { return false }
        cg.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - What a spoken command asks for

    enum Transport: String, Equatable {
        case playPause, next, previous

        var key: Key {
            switch self {
            case .playPause: return .playPause
            case .next: return .next
            case .previous: return .previous
            }
        }

        /// What the HUD says. "Play" and "pause" are the same key — macOS
        /// toggles — so the label has to cover both without claiming which.
        var label: String {
            switch self {
            case .playPause: return "Play/pause"
            case .next: return "Next track"
            case .previous: return "Previous track"
            }
        }

        var spoken: String {
            switch self {
            case .playPause: return "Toggled playback, sir."
            case .next: return "Skipping ahead, sir."
            case .previous: return "Back one, sir."
            }
        }
    }

    /// Longest first, so "previous track" is never read as the bare "track",
    /// and "skip back" never lands on "skip".
    private static let table: [(String, Transport)] = [
        ("go back a track", .previous), ("go back a song", .previous),
        ("previous track", .previous), ("previous song", .previous),
        ("last track", .previous), ("last song", .previous),
        ("skip back", .previous), ("go back", .previous),
        ("next track", .next), ("next song", .next), ("skip track", .next),
        ("skip song", .next), ("skip ahead", .next), ("skip this", .next),
        ("play pause", .playPause), ("pause the music", .playPause),
        ("resume the music", .playPause), ("pause it", .playPause),
        ("previous", .previous), ("next", .next), ("skip", .next),
        ("unpause", .playPause), ("pause", .playPause), ("resume", .playPause),
        ("play", .playPause), ("stop", .playPause),
    ]

    /// Reads a transport command out of the whole sentence.
    ///
    /// Kept here rather than in the resolver because it is the same table the
    /// action needs: one place decides that "skip" means next, so the HUD line
    /// and the key pressed can never disagree.
    ///
    /// Whole-token runs, not substrings. "play" as a substring appears in
    /// "player" and "display", and a command that pauses your music because you
    /// said "display" is worse than one that misses.
    static func transport(for words: String) -> Transport? {
        let haystack = PhraseMatcher.Haystack(PhraseMatcher.normalize(words))
        guard haystack.wordCount > 0 else { return nil }
        for (phrase, transport) in table
        where PhraseMatcher.containsTokenRun(haystack, phrase) {
            return transport
        }
        return nil
    }
}
