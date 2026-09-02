import AppKit

struct ChromeProfile: Equatable {
    /// The on-disk directory name Chrome uses: "Default", "Profile 1", …
    let directory: String
    /// What you named it in Chrome: "Work", "Connor".
    let name: String
    let email: String

    var label: String { email.isEmpty ? name : "\(name) — \(email)" }
}

enum Browser {

    static let chromeBundleID = "com.google.Chrome"

    static func chromeURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID)
    }

    static var isChromeInstalled: Bool { chromeURL() != nil }

    private static var profileCache: (value: [ChromeProfile], at: Date)?

    /// Chrome keeps its profile list in Local State, keyed by directory name.
    /// Cached briefly: this is consulted on every partial transcript.
    static func chromeProfiles() -> [ChromeProfile] {
        if let cache = profileCache, Date().timeIntervalSince(cache.at) < 30 { return cache.value }
        let fresh = loadChromeProfiles()
        profileCache = (fresh, Date())
        return fresh
    }

    private static func loadChromeProfiles() -> [ChromeProfile] {
        let path = NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Local State"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }

        // Preserve Chrome's own ordering where it gives us one.
        let order = (profile["profiles_order"] as? [String]) ?? []
        let keys = order.filter { cache[$0] != nil }
            + cache.keys.filter { !order.contains($0) }.sorted()

        return keys.compactMap { key in
            guard let entry = cache[key] as? [String: Any] else { return nil }
            let name = (entry["name"] as? String) ?? key
            let email = (entry["user_name"] as? String) ?? ""
            return ChromeProfile(directory: key, name: name, email: email)
        }
    }

    static func profileName(for directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        return chromeProfiles().first { $0.directory == directory }?.name
    }

    /// The Google account signed into a profile, when Chrome recorded one.
    static func profileEmail(for directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        let email = chromeProfiles().first { $0.directory == directory }?.email
        return (email?.isEmpty ?? true) ? nil : email
    }

    /// Accounts belonging to every *other* profile — the addresses that, seen in
    /// a window title, mean the tab is not the one this command wants.
    static func otherProfileEmails(excluding directory: String?) -> [String] {
        chromeProfiles()
            .filter { $0.directory != directory && !$0.email.isEmpty }
            .map(\.email)
    }

    /// The argv Chrome is launched with to land in a particular profile.
    ///
    /// Split out so a test can hold it to the one thing that matters: the
    /// profile stays a single argument even when its directory name contains a
    /// space, which "Profile 1" — the second profile Chrome ever makes — does.
    static func chromeArguments(profile: String, url: String?) -> [String] {
        var arguments = ["--profile-directory=\(profile)"]
        // No URL means "just give me a window in that profile".
        if let url, !url.isEmpty { arguments.append(url) }
        return arguments
    }

    /// The executable inside an app bundle, per its own Info.plist.
    static func executable(inside bundle: URL) -> URL? {
        guard let name = Bundle(url: bundle)?.infoDictionary?["CFBundleExecutable"] as? String,
              !name.isEmpty
        else { return nil }
        return bundle.appendingPathComponent("Contents/MacOS/\(name)")
    }

    /// Opens a URL, optionally forcing a specific Chrome profile.
    ///
    /// Runs Chrome's own binary rather than `/usr/bin/open -n -a … --args …`.
    /// What follows `--args` is re-split on whitespace somewhere between `open`
    /// and the app, so a profile directory with a space arrived as
    /// `--profile-directory=Profile`, no such profile existed, and Chrome
    /// quietly opened Default instead — "open chrome on personal" looked like
    /// it worked and gave you the wrong account. An argv array passed straight
    /// to the binary keeps the argument whole.
    ///
    /// It is still a *new* instance, which is the part that always mattered:
    /// launch arguments only reach a new one, and it routes the request into
    /// the requested profile before exiting. A running Chrome asked merely to
    /// activate comes forward with the profile flag dropped.
    @discardableResult
    static func open(_ urlString: String?, chromeProfile: String?) -> Bool {
        if let profile = chromeProfile, !profile.isEmpty,
           launch(profile: profile, url: urlString) {
            return true
        }

        guard let urlString, !urlString.isEmpty else {
            guard let chrome = chromeURL() else { return false }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: chrome, configuration: config, completionHandler: nil)
            return true
        }
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Starts a new Chrome instance pointed at a profile. See `open` for why
    /// the binary runs directly rather than through `open(1)`.
    private static func launch(profile: String, url: String?) -> Bool {
        guard let chrome = chromeURL(), let binary = executable(inside: chrome)
        else { return false }
        let process = Process()
        process.executableURL = binary
        process.arguments = chromeArguments(profile: profile, url: url)
        return (try? process.run()) != nil
    }

    // MARK: - A window in a particular profile

    /// Window ids Jarvis has opened for each profile.
    ///
    /// Chrome will not say which profile a window belongs to — the same wall
    /// `pickTab` runs into — so there is nothing to ask. This learns it the
    /// only way available: note which window appears when we launch a profile,
    /// and remember it. Touched only on `scriptQueue`, which is serial.
    private static var profileWindows: [String: Int] = [:]

    /// Brings up a window in a particular Chrome profile, reusing one already
    /// open for it rather than stacking up new ones.
    ///
    /// "Already open for it" is the whole difficulty. Two signals stand in for
    /// the profile Chrome won't report, in order of how much they can be
    /// trusted: a window Jarvis itself opened for this profile earlier, and a
    /// window showing a page signed into this profile's account — the same
    /// account-in-the-title trick `pickTab` uses. Miss both and it opens a new
    /// window, which is what happened every time before.
    static func openProfileWindow(_ profile: String, reuseExisting: Bool,
                                  completion: @escaping (Bool) -> Void) {
        scriptQueue.async {
            if reuseExisting {
                if let known = profileWindows[profile] {
                    if focusWindow(known) {
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                    profileWindows[profile] = nil   // that window is gone
                }
                if let email = profileEmail(for: profile),
                   let found = window(showing: email), focusWindow(found) {
                    profileWindows[profile] = found
                    DispatchQueue.main.async { completion(true) }
                    return
                }
            }

            let before = windowIDs()
            guard launch(profile: profile, url: nil) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.async { completion(true) }

            // Note which window Chrome put up, so asking again focuses this one
            // rather than opening another. Runs after the caller has been told
            // the command succeeded, so the spoken reply doesn't wait on it.
            for _ in 0..<16 {
                Thread.sleep(forTimeInterval: 0.25)
                if let fresh = windowIDs().subtracting(before).first {
                    profileWindows[profile] = fresh
                    return
                }
            }
        }
    }

    /// Every open Chrome window, by its own id.
    private static func windowIDs() -> Set<Int> {
        let source = """
        set out to ""
        with timeout of 3 seconds
            tell application "Google Chrome"
                if not running then return ""
                repeat with w in windows
                    set out to out & (id of w) & linefeed
                end repeat
            end tell
        end timeout
        return out
        """
        guard let raw = runScript(source) else { return [] }
        return Set(raw.split(separator: "\n").compactMap { Int($0) })
    }

    /// The window holding a tab signed into `email`, if there is one. Matching
    /// happens inside Chrome so only the window id has to come back.
    private static func window(showing email: String) -> Int? {
        guard !email.isEmpty else { return nil }
        let source = """
        with timeout of 3 seconds
            tell application "Google Chrome"
                if not running then return ""
                repeat with w in windows
                    repeat with t in tabs of w
                        if (title of t) contains "\(escapeForAppleScript(email))" then
                            return (id of w) as text
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        return ""
        """
        guard let raw = runScript(source) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Brings one Chrome window to the front by its own id.
    private static func focusWindow(_ id: Int) -> Bool {
        let source = """
        with timeout of 3 seconds
            tell application "Google Chrome"
                if not running then return "NONE"
                repeat with w in windows
                    -- Chrome hands back an id that never compares equal to a
                    -- bare number; without the coercion this matches nothing.
                    if ((id of w) as text) is "\(id)" then
                        set index of w to 1
                        activate
                        return "OK"
                    end if
                end repeat
            end tell
        end timeout
        return "NONE"
        """
        return runScript(source) == "OK"
    }

    // MARK: - A fresh tab or window

    /// What a spoken "new tab" or "new window" asks the browser to make.
    enum Fresh: String { case tab, window }

    private static let scriptQueue = DispatchQueue(label: "jarvis.applescript")

    /// Makes a fresh tab or window in Chrome.
    ///
    /// There is no launch flag for this. `open -a "Google Chrome"` on a running
    /// Chrome just activates it, which is why "open a new tab" used to do
    /// nothing but bring the window you already had to the front. Chrome's
    /// scripting interface is the only way to ask for a tab, so this goes
    /// through AppleScript like tab reuse does and wants the same Automation
    /// permission. Any failure — refused, slow, no Chrome — reports false so
    /// the caller can fall back to simply opening the browser.
    static func openFresh(_ what: Fresh, completion: @escaping (Bool) -> Void) {
        let body: String
        switch what {
        case .window:
            body = "make new window"
        case .tab:
            // There has to be a window before it can hold a tab.
            body = """
            if (count of windows) is 0 then
                        make new window
                    else
                        make new tab at end of tabs of front window
                    end if
            """
        }

        let source = """
        with timeout of 5 seconds
            tell application "Google Chrome"
                activate
                \(body)
            end tell
        end timeout
        return "OK"
        """

        scriptQueue.async {
            let made = runScript(source) == "OK"
            DispatchQueue.main.async { completion(made) }
        }
    }

    // MARK: - Reusing an open tab

    /// True when an already-open tab is close enough to count as "the same page".
    /// Host must match (ignoring www.); if the target names a path, the tab's
    /// path has to start with it.
    static func tabMatches(_ tabURL: String, target: String) -> Bool {
        func host(_ url: URL) -> String? {
            guard let host = url.host?.lowercased() else { return nil }
            // Only a leading "www.", the way matchPrefixes does it — stripping
            // it anywhere would fold "news.www.example.com" onto the wrong host.
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        guard let wanted = URL(string: target), let open = URL(string: tabURL),
              let wantedHost = host(wanted), let openHost = host(open),
              wantedHost == openHost
        else { return false }

        let wantedPath = wanted.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if wantedPath.isEmpty { return true }
        // Compare against the same trimmed path the emptiness test used, so a
        // target written with a trailing slash still matches the tab without one.
        return open.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .hasPrefix(wantedPath)
    }

    private static func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    /// URL prefixes that should count as "this page is already open".
    static func matchPrefixes(for urlString: String) -> [String] {
        guard let url = URL(string: urlString), let host = url.host?.lowercased()
        else { return [] }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.isEmpty ? "" : "/\(path)"
        var prefixes: [String] = []
        for scheme in ["https", "http"] {
            for candidate in [bare, "www.\(bare)"] {
                prefixes.append("\(scheme)://\(candidate)\(suffix)")
            }
        }
        return prefixes
    }

    private static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// A tab that already has the wanted page open.
    struct OpenTab: Equatable {
        /// Chrome's own window id. Stable while the window lives, unlike the
        /// z-order index, which shifts the moment anything comes to the front.
        let windowID: Int
        let tabIndex: Int
        let url: String
        let title: String
    }

    /// Decides which open tab — if any — a command should be sent to.
    ///
    /// Chrome tells scripts nothing about which profile a window belongs to, so
    /// a command pinned to a profile can't simply jump to the first tab with a
    /// matching URL: school Gmail and personal Gmail look identical from here.
    /// Two things stand in for the profile Chrome won't report:
    ///
    /// 1. Signed-in Google pages put the account in the window title — "Inbox
    ///    (2) - you@school.edu - Mail". When a title names an account we can
    ///    match it against the profile's own address exactly, and a tab that
    ///    names a *different* account is ruled out rather than guessed at.
    /// 2. Titles that name no account (Schoology, Drive, YouTube) fall back to
    ///    being unambiguous: one window holding the page means there is nothing
    ///    to confuse it with. Copies in two windows might be two profiles, so
    ///    we decline and let the caller open it in the pinned profile instead.
    ///
    /// Unpinned commands skip all of this — no profile to get wrong.
    static func pickTab(from candidates: [OpenTab],
                        profileEmail: String?,
                        otherEmails: [String]) -> OpenTab? {
        guard !candidates.isEmpty else { return nil }

        let mine = (profileEmail ?? "").lowercased()
        guard !mine.isEmpty else { return candidates.first }

        let theirs = otherEmails.map { $0.lowercased() }
            .filter { !$0.isEmpty && $0 != mine }

        var neutral: [OpenTab] = []
        for tab in candidates {
            let title = tab.title.lowercased()
            if title.contains(mine) { return tab }
            if theirs.contains(where: { title.contains($0) }) { continue }
            neutral.append(tab)
        }

        // Unambiguous only if every copy is in the same window.
        guard let first = neutral.first,
              neutral.allSatisfy({ $0.windowID == first.windowID })
        else { return nil }
        return first
    }

    /// Every open tab showing this page, across the frontmost few windows.
    ///
    /// Capped on purpose: Chrome answers scripting requests slowly once a lot of
    /// windows are open, and asking about every tab in the browser reliably blew
    /// past the timeout. The window you mean is almost always one you used recently.
    private static func openTabs(matching urlString: String) -> [OpenTab] {
        let prefixes = matchPrefixes(for: urlString)
        guard !prefixes.isEmpty else { return [] }
        let list = prefixes.map { "\"\(escapeForAppleScript($0))\"" }.joined(separator: ", ")

        // `tab` is a Chrome class, so the tab character has to come in under
        // another name or the tell block reads it as the class.
        let source = """
        on scrub(t)
            set saved to AppleScript's text item delimiters
            repeat with bad in {linefeed, return, character id 9}
                set AppleScript's text item delimiters to bad
                set parts to text items of t
                set AppleScript's text item delimiters to " "
                set t to parts as text
            end repeat
            set AppleScript's text item delimiters to saved
            return t
        end scrub

        set TB to character id 9
        set wanted to {\(list)}
        set out to ""
        with timeout of 3 seconds
            tell application "Google Chrome"
                if not running then return ""
                set wc to count of windows
                if wc > 6 then set wc to 6
                repeat with wi from 1 to wc
                    set w to window wi
                    set wid to id of w
                    set urls to URL of tabs of w
                    set names to title of tabs of w
                    repeat with ti from 1 to count of urls
                        set u to item ti of urls
                        repeat with p in wanted
                            if u starts with p then
                                set nm to ""
                                if ti ≤ (count of names) then set nm to item ti of names
                                set out to out & wid & TB & ti & TB & u & TB & my scrub(nm) & linefeed
                                exit repeat
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end timeout
        return out
        """

        return parseTabs(runScript(source) ?? "")
    }

    /// One tab per line: window id, tab index, URL, title. Anything malformed is
    /// dropped rather than guessed at — a mangled line would only ever make a tab
    /// look account-less, which is the cautious direction.
    static func parseTabs(_ raw: String) -> [OpenTab] {
        raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let windowID = Int(parts[0]), let tabIndex = Int(parts[1])
            else { return nil }
            return OpenTab(windowID: windowID, tabIndex: tabIndex,
                           url: String(parts[2]), title: String(parts[3]))
        }
    }

    /// Focuses a tab found by `openTabs`, addressing the window by id and the tab
    /// by URL. Both survive the user reordering windows or tabs in between; the
    /// index we listed it under would not.
    private static func focus(_ tab: OpenTab) -> Bool {
        let source = """
        with timeout of 3 seconds
            tell application "Google Chrome"
                if not running then return "NONE"
                repeat with wi from 1 to count of windows
                    set w to window wi
                    -- Chrome hands back an id that never compares equal to a bare
                    -- number; without the coercion this loop silently matches nothing.
                    if ((id of w) as text) is "\(tab.windowID)" then
                        set urls to URL of tabs of w
                        repeat with ti from 1 to count of urls
                            if (item ti of urls) is "\(escapeForAppleScript(tab.url))" then
                                set active tab index of w to ti
                                set index of w to 1
                                activate
                                return "OK"
                            end if
                        end repeat
                    end if
                end repeat
            end tell
        end timeout
        return "NONE"
        """
        return runScript(source) == "OK"
    }

    /// Brings an already-open tab for this URL to the front.
    ///
    /// Needs Automation permission for Chrome, asked once. Any failure — denied,
    /// slow, no match, wrong profile — reports false so the caller just opens a
    /// new tab.
    static func focusExistingTab(matching urlString: String,
                                 profileEmail: String? = nil,
                                 otherEmails: [String] = [],
                                 completion: @escaping (Bool) -> Void) {
        scriptQueue.async {
            let candidates = openTabs(matching: urlString)
            guard let tab = pickTab(from: candidates,
                                    profileEmail: profileEmail,
                                    otherEmails: otherEmails) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let focused = focus(tab)
            DispatchQueue.main.async { completion(focused) }
        }
    }

    /// Consumer mail hosts — used to tell a personal profile from a work one.
    private static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "icloud.com", "me.com", "mac.com", "yahoo.com", "aol.com",
        "proton.me", "protonmail.com",
    ]

    private static func isPersonal(_ profile: ChromeProfile) -> Bool {
        guard let domain = profile.email.split(separator: "@").last?.lowercased() else { return false }
        return personalDomains.contains(domain)
    }

    /// Resolves a spoken profile word — "work", "school", "personal", or the
    /// profile's own name — to a Chrome profile.
    ///
    /// Falls back to the mail domain so "school" finds a school.edu profile
    /// and "personal" finds a gmail one, without you having to configure aliases.
    /// Returns nil when it can't tell, so an unclear word never picks a profile.
    static func matchProfile(_ spoken: String, in profiles: [ChromeProfile]? = nil) -> ChromeProfile? {
        let all = profiles ?? chromeProfiles()
        let word = PhraseMatcher.normalize(spoken)
        guard !word.isEmpty, !all.isEmpty else { return nil }

        var best: (ChromeProfile, Double)?
        for profile in all {
            let name = PhraseMatcher.normalize(profile.name)
            let score = max(PhraseMatcher.scoreNormalized(name, word),
                            PhraseMatcher.scoreNormalized(word, name))
            if score >= 0.82, score > (best?.1 ?? 0) { best = (profile, score) }
        }
        if let best { return best.0 }

        for profile in all {
            guard let local = profile.email.split(separator: "@").first else { continue }
            if PhraseMatcher.scoreNormalized(PhraseMatcher.normalize(String(local)), word) >= 0.88 {
                return profile
            }
        }

        let workWords: Set<String> = ["work", "school", "uni", "university", "college",
                                      "class", "business", "office", "job"]
        let personalWords: Set<String> = ["personal", "home", "private", "own", "me", "myself"]

        if workWords.contains(word) {
            let candidates = all.filter { !$0.email.isEmpty && !isPersonal($0) }
            if candidates.count == 1 { return candidates[0] }
        }
        if personalWords.contains(word) {
            let candidates = all.filter { isPersonal($0) }
            if candidates.count == 1 { return candidates[0] }
        }
        return nil
    }
}
