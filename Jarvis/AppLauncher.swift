import AppKit

enum AppLauncher {

    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Bundle-ID lookup first (works wherever the app lives), then the usual spots.
    static func claudeURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Claude.app"),
            home.appendingPathComponent("Applications/Claude.app"),
            home.appendingPathComponent("Desktop/Claude.app"),
            home.appendingPathComponent("Downloads/Claude.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Brings Claude to the front, launching it if it isn't already running.
    static func openClaude(completion: @escaping (Error?) -> Void) {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: claudeBundleID).first {
            running.activate(options: [.activateAllWindows])
            // Re-open so a hidden/closed-window instance shows something.
            if let url = claudeURL() {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                    DispatchQueue.main.async { completion(error) }
                }
                return
            }
            completion(nil)
            return
        }

        guard let url = claudeURL() else {
            completion(NSError(
                domain: "Jarvis", code: 404,
                userInfo: [NSLocalizedDescriptionKey:
                    "Couldn't find Claude.app. Move it to /Applications or open Jarvis's menu and pick it manually."]))
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
