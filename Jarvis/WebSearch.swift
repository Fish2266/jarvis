import Foundation

/// Turns "search for how to poach an egg" into a URL.
///
/// The engine is whatever the command's Target says, so this is not really
/// about Google: point a second command at YouTube's or Amazon's search URL
/// and "search youtube for …" works the same way, with no code here knowing
/// about either.
enum WebSearch {

    static let google = "https://www.google.com/search?q="

    /// Where the query goes, when it isn't simply on the end.
    ///
    /// Most engines take the query as the last parameter, so appending is the
    /// default. Some want it in the middle of the path — a `%s` anywhere in
    /// the target says exactly where.
    static let placeholder = "%s"

    /// Builds the search URL, or nil if there is nothing to search for.
    ///
    /// The query is percent-encoded as a *query component*, which is stricter
    /// than it sounds: `&`, `=`, `+` and `#` are all legal in a URL yet all
    /// change what the search engine receives, so each is escaped rather than
    /// passed through. "c# vs f#" searches for what you said instead of for "c".
    static func url(for query: String, engine: String = google) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/;:$,@")
        guard let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }

        let base = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = base.isEmpty ? google : base
        let text = target.contains(placeholder)
            ? target.replacingOccurrences(of: placeholder, with: escaped)
            : target + escaped
        return URL(string: text)
    }

    /// What the HUD says: the query, shortened rather than allowed to run off
    /// the screen. The headline is a line of text, not a paragraph.
    static func headline(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 46 else { return "Searching for \(trimmed)" }
        return "Searching for \(trimmed.prefix(45))…"
    }
}
