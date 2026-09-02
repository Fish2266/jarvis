import AppKit

/// Brings a running app's windows to the desktop you're looking at.
///
/// There is no public API for this. Nothing in AppKit or CoreGraphics can move
/// another app's window between Mission Control desktops — the window server
/// owns that, and the only way in is SkyLight, which is private. So every
/// symbol is resolved at run time and every call degrades to "did nothing":
/// if a lookup fails, or a future macOS stops honouring it, `bring` returns
/// false and the caller opens the app the ordinary way instead.
///
/// Only the process id is needed. Moving individual windows would have meant
/// enumerating them, which costs Screen Recording permission, and raising one
/// afterwards would have cost Accessibility. This asks for neither — the same
/// bargain `EscapeHotKey` makes by using Carbon hot keys over an event tap.
enum Spaces {

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias GetActiveSpace   = @convention(c) (Int32) -> UInt64
    private typealias AssignToSpace    = @convention(c) (Int32, pid_t, UInt64) -> Int32

    /// Looked up once. nil means this macOS doesn't expose what we need, and
    /// everything below turns into a no-op.
    private static let api: (cid: Int32,
                             activeSpace: GetActiveSpace,
                             assign: AssignToSpace)? = {
        guard let handle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let active = dlsym(handle, "SLSGetActiveSpace"),
              let assign = dlsym(handle, "SLSProcessAssignToSpace")
        else { return nil }

        let cid = unsafeBitCast(connection, to: MainConnectionID.self)()
        guard cid != 0 else { return nil }
        return (cid,
                unsafeBitCast(active, to: GetActiveSpace.self),
                unsafeBitCast(assign, to: AssignToSpace.self))
    }()

    static var isAvailable: Bool { api != nil }

    /// Moves every window belonging to `pid` onto the desktop you're on.
    ///
    /// Assignment is per process, not per window: the per-window call the
    /// window server also offers (`SLSMoveWindowsToManagedSpace`) is refused
    /// while System Integrity Protection is on, and this one isn't. So an app
    /// whose windows are spread across several desktops gets all of them
    /// collected here, which is what "bring xcode over" usually means anyway.
    ///
    /// The assignment is cleared immediately afterwards. Left in place it is
    /// exactly the Dock's "Assign To ▸ This Desktop": the app would be pinned
    /// here permanently and every later window would follow it. Clearing it
    /// leaves the windows where they were just put and pins nothing — the
    /// windows do not spring back.
    @discardableResult
    static func bring(pid: pid_t) -> Bool {
        guard let api else { return false }
        let destination = api.activeSpace(api.cid)
        guard destination != 0 else { return false }
        guard api.assign(api.cid, pid, destination) == 0 else { return false }
        _ = api.assign(api.cid, pid, 0)
        return true
    }

    /// The running instance of the app installed at `path`, if there is one.
    ///
    /// Falls back to the bundle identifier, and that fallback is the common
    /// case rather than the exotic one: anything launched from Downloads runs
    /// *translocated* — macOS copies the bundle to a random read-only path
    /// under /private/var/folders and runs it from there — so the running app's
    /// bundleURL never equals where it lives on disk. Matching only on path
    /// meant "bring over minecraft" found nothing and quietly fell through to
    /// an ordinary activate, which looks exactly like the feature not working.
    static func runningApp(atPath path: String) -> NSRunningApplication? {
        guard !path.isEmpty else { return nil }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL
        let running = NSWorkspace.shared.runningApplications

        if let exact = running.first(where: { $0.bundleURL?.standardizedFileURL == wanted }) {
            return exact
        }
        guard let identifier = Bundle(url: wanted)?.bundleIdentifier else { return nil }
        return running.first { $0.bundleIdentifier == identifier }
    }
}
