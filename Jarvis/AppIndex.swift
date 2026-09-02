import AppKit

/// A cached list of installed apps, so "open chrome" works without you having
/// to write a macro for every app on the Mac.
final class AppIndex {

    static let shared = AppIndex()

    struct Entry {
        let name: String        // "Google Chrome"
        let normalized: String  // "google chrome"
        let path: String
    }

    private(set) var entries: [Entry] = []
    private var scanning = false
    private var lastScan = Date.distantPast

    private init() {}

    private static var searchRoots: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
            "\(home)/Desktop",
            "\(home)/Downloads",
        ]
    }

    /// Cheap enough to do off the main thread at launch and after a change.
    @discardableResult
    func refresh() -> [Entry] {
        var found: [String: Entry] = [:]   // keyed by normalized name, first wins
        let fm = FileManager.default

        func consider(_ path: String) {
            guard path.hasSuffix(".app") else { return }
            let display = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
            let key = PhraseMatcher.normalize(display)
            guard !key.isEmpty, found[key] == nil else { return }
            found[key] = Entry(name: display, normalized: key, path: path)
        }

        for root in Self.searchRoots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = "\(root)/\(item)"
                if item.hasSuffix(".app") {
                    consider(path)
                } else {
                    // One level down catches things like "Adobe Photoshop 2026/Photoshop.app".
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                          let nested = try? fm.contentsOfDirectory(atPath: path) else { continue }
                    for child in nested where child.hasSuffix(".app") {
                        consider("\(path)/\(child)")
                    }
                }
            }
        }

        let list = found.values.sorted { $0.name < $1.name }
        let publish = {
            self.entries = list
            self.lastScan = Date()
            self.scanning = false
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
        return list
    }

    /// Scans in the background unless one has finished recently.
    ///
    /// `scanning` is raised before leaving the main thread on purpose. It used
    /// to be a "loaded" flag set only once the scan had finished and hopped
    /// back to main, so two calls close together both saw an empty index and
    /// walked every directory twice.
    func refreshIfStale(after interval: TimeInterval) {
        guard !scanning, Date().timeIntervalSince(lastScan) > interval else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { self.refresh() }
    }

    /// The first scan, at launch.
    func ensureLoaded() { refreshIfStale(after: 0) }

    /// How long an index can go without a re-scan. Installing an app should
    /// not mean restarting Jarvis before "open <it>" can find it, and the walk
    /// costs a few milliseconds off the main thread.
    static let staleAfter: TimeInterval = 300

    /// Best app whose name matches `target`, above `threshold`.
    func best(matching target: String, threshold: Double) -> (Entry, Double)? {
        guard !target.isEmpty else { return nil }
        var winner: (Entry, Double)?
        for entry in entries {
            let score: Double
            if entry.normalized == target {
                score = 1.0
            } else if PhraseMatcher.containsTokenRun(entry.normalized, target) {
                // "chrome" finds "Google Chrome".
                score = 0.95
            } else {
                // Forward direction only. Scoring the other way lets a one-typo
                // budget match "News" against "new"; the "chrome" -> "Google
                // Chrome" case that needed it is handled by containsTokenRun.
                score = PhraseMatcher.similarityNormalized(entry.normalized, target)
            }
            if score >= threshold, score > (winner?.1 ?? 0) {
                winner = (entry, score)
            }
        }
        return winner
    }
}
