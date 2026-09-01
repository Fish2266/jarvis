import Foundation
import CoreGraphics

func post(_ name: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.connorchristopherson.Jarvis.\(name)"),
        object: nil, userInfo: nil, deliverImmediately: true)
}
func overlayUp() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    return ((list as? [[String: Any]]) ?? []).contains { w in
        guard (w[kCGWindowOwnerName as String] as? String) == "Jarvis",
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return b["Width"]! > 500 && b["Height"]! > 400
    }
}
func waitFor(_ want: Bool, limit: Double) -> Double? {
    let start = Date()
    while Date().timeIntervalSince(start) < limit {
        if overlayUp() == want { return Date().timeIntervalSince(start) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return nil
}
var failures = 0
func check(_ l: String, _ p: Bool, _ d: String = "") {
    print("\(p ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  [\(d)]")"); if !p { failures += 1 }
}

// Jarvis needs a moment after launch to get the mic running; arming before it
// is listening is correctly a no-op, so don't race it.
print("waiting for Jarvis to settle…")
Thread.sleep(forTimeInterval: 6)

print("=== arm, then cancel ===")
post("arm")
if let t = waitFor(true, limit: 3) {
    check("HUD comes up on arm", true, String(format: "%.2fs", t))
} else { check("HUD comes up on arm", false) }

Thread.sleep(forTimeInterval: 1.0)
post("cancel")
if let t = waitFor(false, limit: 3) {
    check("cancel tears the HUD down fast", t < 1.5, String(format: "%.2fs", t))
} else { check("cancel tears the HUD down fast", false, "still up after 3s") }

Thread.sleep(forTimeInterval: 1.5)

print("\n=== arm, say nothing, stand down on its own ===")
post("arm")
_ = waitFor(true, limit: 3)
let standStart = Date()
if let _ = waitFor(false, limit: 12) {
    let elapsed = Date().timeIntervalSince(standStart)
    // 6s listening window + the stand-down fade.
    check("stands down after the listening window", elapsed > 4 && elapsed < 11,
          String(format: "%.1fs", elapsed))
} else { check("stands down after the listening window", false, "never went away") }

Thread.sleep(forTimeInterval: 1.5)

print("\n=== full trigger ===")
post("trigger")
if let t = waitFor(true, limit: 3) {
    check("HUD comes up on trigger", true, String(format: "%.2fs", t))
} else { check("HUD comes up on trigger", false) }
_ = waitFor(false, limit: 8)
check("HUD cleaned itself up", !overlayUp())

print("\n\(failures == 0 ? "ALL INTEGRATION CHECKS PASSED" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
