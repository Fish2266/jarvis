import AppKit

/// Putting things on the clipboard and reading them back.
///
/// The one command here that is genuinely about *dictation*: everything else
/// Jarvis does with what you say is to work out which action you meant, and
/// this simply keeps the words. Useful for the thing you want in a minute and
/// don't want to open an app for — a phone number read out to you, an address,
/// a line you thought of on the way past.
///
/// No permission, no file, nothing written to disk. `NSPasteboard` is the same
/// clipboard ⌘C uses, so it is already wherever you were going to paste it.
enum Clipboard {

    /// Replaces the clipboard's contents. Returns whether anything was put
    /// there — an empty dictation is not worth throwing away what you had.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(trimmed, forType: .string)
    }

    /// The clipboard as text, or nil when it holds something that isn't —
    /// an image, a file, a slice of a spreadsheet.
    static func read() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the clipboard holds, said out loud.
    ///
    /// Long clipboards are described rather than recited. Reading four hundred
    /// words of copied article aloud is not an answer to "what's on my
    /// clipboard", it is a hostage situation — so past a sentence or two it
    /// says how much there is and reads the beginning.
    static func spokenSummary() -> String {
        guard let text = read() else {
            return "Nothing I can read on the clipboard, sir."
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 40 else {
            return "The clipboard says: \(text)"
        }
        let opening = words.prefix(25).joined(separator: " ")
        return "\(words.count) words, sir. It begins: \(opening)…"
    }

    /// What to show on the HUD after copying — the text, shortened.
    static func headline(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return "Copied \u{201C}\(trimmed)\u{201D}" }
        return "Copied \u{201C}\(trimmed.prefix(39))…\u{201D}"
    }
}
