import Foundation
import IOKit.ps

/// Things the Mac already knows about itself, read straight from the system.
///
/// All of it exists so the model never has to guess. Asked how much battery is
/// left, a language model will produce a confident, plausible, wrong number —
/// the same failure that made "what time is it" an answer from the clock
/// rather than from the model. Anything with an exact answer should have one.
///
/// Every read here is a syscall or a framework call measured in microseconds,
/// and none of it runs unless something asks.
enum SystemInfo {

    // MARK: - Battery

    struct Battery {
        /// 0…100.
        let percent: Int
        let charging: Bool
        /// True on a Mac with no battery at all.
        let onACOnly: Bool
        /// Minutes left, when the system is willing to estimate. It says −1
        /// for "still working it out", which is not a number to read aloud.
        let minutesRemaining: Int?
    }

    static func battery() -> Battery? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = state == kIOPSACPowerValue
            let raw = charging
                ? (description[kIOPSTimeToFullChargeKey] as? Int)
                : (description[kIOPSTimeToEmptyKey] as? Int)
            let minutes = (raw ?? -1) > 0 ? raw : nil

            return Battery(percent: Int((Double(capacity) / Double(max) * 100).rounded()),
                           charging: charging,
                           onACOnly: onAC && !charging,
                           minutesRemaining: minutes)
        }
        return nil
    }

    /// "Seventy-one percent, sir. Around two hours and ten minutes left."
    static func batteryLine() -> String? {
        guard let battery = battery() else { return nil }
        var line = "Battery is at \(battery.percent) percent, sir."
        if battery.charging {
            line += battery.minutesRemaining.map { " Full in \(duration($0))." } ?? " Charging."
        } else if battery.onACOnly {
            line += " Running on power."
        } else if let minutes = battery.minutesRemaining {
            line += " About \(duration(minutes)) left."
        }
        return line
    }

    /// Minutes as something worth hearing: "two hours and ten minutes", not "130".
    static func duration(_ minutes: Int) -> String {
        guard minutes > 0 else { return "no time" }
        let hours = minutes / 60
        let rest = minutes % 60
        func plural(_ n: Int, _ word: String) -> String {
            "\(n) \(word)\(n == 1 ? "" : "s")"
        }
        if hours == 0 { return plural(rest, "minute") }
        if rest == 0 { return plural(hours, "hour") }
        return "\(plural(hours, "hour")) and \(plural(rest, "minute"))"
    }

    // MARK: - Disk

    /// Free space on the boot volume, in bytes.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` rather than the plain
    /// available capacity: on APFS the plain figure ignores space macOS would
    /// purge on demand, and reads tens of gigabytes low on a Mac full of
    /// purgeable caches. This is the number Finder shows.
    static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                      .volumeAvailableCapacityKey])
        else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    static func totalDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        return Int64(total)
    }

    static func diskLine() -> String? {
        guard let free = freeDiskBytes() else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        var line = "\(formatter.string(fromByteCount: free)) free, sir."
        if let total = totalDiskBytes(), total > 0 {
            line += " That's \(Int((Double(free) / Double(total) * 100).rounded())) percent of the disk."
        }
        return line
    }

    // MARK: - Uptime

    /// How long since the Mac last booted.
    static func uptime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else { return nil }
        let booted = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        let elapsed = Date().timeIntervalSince(booted)
        return elapsed > 0 ? elapsed : nil
    }

    static func uptimeLine() -> String? {
        guard let seconds = uptime() else { return nil }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        if days >= 1 {
            let rest = (minutes % 1440) / 60
            var line = "Up \(days) day\(days == 1 ? "" : "s")"
            if rest > 0 { line += " and \(rest) hour\(rest == 1 ? "" : "s")" }
            return line + ", sir."
        }
        return "Up \(duration(minutes)), sir."
    }

    // MARK: - Network

    /// The Wi-Fi or Ethernet address this Mac has on the local network.
    ///
    /// Deliberately the *local* one. The public address would mean a network
    /// round trip to somebody else's server to answer a question about your own
    /// machine, and everything else here is answered without leaving the Mac.
    static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            let name = String(cString: current.pointee.ifa_name)
            // en0 is Wi-Fi on every Mac that has it; prefer it over the
            // bridges and virtual interfaces that also answer.
            if name == "en0" { return text }
            if fallback == nil { fallback = text }
        }
        return fallback
    }

    static func networkLine() -> String? {
        guard let address = localAddress() else { return "You're not on a network, sir." }
        return "This Mac is \(address) on the local network, sir."
    }
}
