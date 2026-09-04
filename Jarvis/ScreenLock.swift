import Foundation

/// Locks the screen. Nothing else.
///
/// Same bargain as `SystemPower`: one thing, no input, no path from a spoken
/// phrase to anything else. And the same bargain as `Spaces`: the symbol is
/// resolved at run time, so a future macOS that stops publishing it turns this
/// into "did nothing" rather than a crash.
///
/// Deliberately not a second process launch. `pmset displaysleepnow` would put
/// the display to sleep, which locks the Mac only if the password setting says
/// "immediately" — so on a default install it looks like the command silently
/// failed. This is the call the Apple menu's own Lock Screen item makes, so it
/// locks whatever the setting says.
enum ScreenLock {

    private typealias LockScreen = @convention(c) () -> Int32

    /// Looked up once. nil means this macOS doesn't publish it and `lock`
    /// reports failure rather than pretending.
    private static let entry: LockScreen? = {
        guard let handle = dlopen(
                "/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockScreen.self)
    }()

    static var isAvailable: Bool { entry != nil }

    @discardableResult
    static func lock() -> Bool {
        guard let entry else { return false }
        return entry() == 0
    }
}
