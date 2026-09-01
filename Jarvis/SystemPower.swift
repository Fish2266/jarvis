import Foundation

/// Puts the Mac to sleep. Nothing else.
///
/// Deliberately not a general "run a command" action: the command is hardcoded
/// and takes no input, so there is no path from a spoken phrase — or from the
/// language model — to shutting down or restarting. `pmset sleepnow` is the
/// only thing this file can do.
enum SystemPower {

    @discardableResult
    static func sleepNow() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
