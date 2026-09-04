import AppKit
import ApplicationServices

/// Moves the window you are looking at — half the screen, a corner, the lot.
///
/// The one thing in the app that reaches into *another* application's window,
/// and the only way to do that is the accessibility API, which is why this
/// needs the same grant the desktop-switching gestures do. Without it every
/// call reports false and the caller says what is missing rather than doing
/// nothing quietly.
///
/// Every request is bounded by a **half-second messaging timeout**. Asking an
/// app about its windows is a synchronous round trip into that app's run loop,
/// so a process that is beachballing would otherwise hang the main thread here
/// for as long as it felt like — and this runs while the HUD is animating.
enum WindowManager {

    /// The same grant `Spaces` needs, asked through it so there is one answer
    /// to "is Jarvis trusted" rather than two that can disagree.
    static var available: Bool { Spaces.canSwitchDesktops }

    /// How long to wait on the app that owns the window.
    private static let timeout: Float = 0.5

    enum Placement: Equatable {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
        case maximize, center, fullScreen

        var label: String {
            switch self {
            case .left:        return "Left half"
            case .right:       return "Right half"
            case .top:         return "Top half"
            case .bottom:      return "Bottom half"
            case .topLeft:     return "Top left"
            case .topRight:    return "Top right"
            case .bottomLeft:  return "Bottom left"
            case .bottomRight: return "Bottom right"
            case .maximize:    return "Maximised"
            case .center:      return "Centred"
            case .fullScreen:  return "Full screen"
            }
        }

        var spoken: String {
            switch self {
            case .maximize:   return "Filled the screen, sir."
            case .center:     return "Centred, sir."
            case .fullScreen: return "Toggled full screen, sir."
            default:          return "\(label), sir."
            }
        }

        /// The fraction of the visible screen this placement occupies, as
        /// (x, y, width, height) with y measured from the *bottom* — AppKit's
        /// convention, converted once on the way out.
        var fractions: (CGFloat, CGFloat, CGFloat, CGFloat)? {
            switch self {
            case .left:        return (0, 0, 0.5, 1)
            case .right:       return (0.5, 0, 0.5, 1)
            case .top:         return (0, 0.5, 1, 0.5)
            case .bottom:      return (0, 0, 1, 0.5)
            case .topLeft:     return (0, 0.5, 0.5, 0.5)
            case .topRight:    return (0.5, 0.5, 0.5, 0.5)
            case .bottomLeft:  return (0, 0, 0.5, 0.5)
            case .bottomRight: return (0.5, 0, 0.5, 0.5)
            case .maximize:    return (0, 0, 1, 1)
            // Centring keeps the window's own size, and full screen is the
            // window's own affair — neither is a rectangle of the screen.
            case .center, .fullScreen: return nil
            }
        }
    }

    // MARK: - Reading what a spoken command asks for

    /// Longest first, so "top left" is never read as "left".
    private static let table: [(String, Placement)] = [
        ("top left", .topLeft), ("upper left", .topLeft),
        ("top right", .topRight), ("upper right", .topRight),
        ("bottom left", .bottomLeft), ("lower left", .bottomLeft),
        ("bottom right", .bottomRight), ("lower right", .bottomRight),
        ("left half", .left), ("right half", .right),
        ("top half", .top), ("bottom half", .bottom),
        ("full screen", .fullScreen), ("fullscreen", .fullScreen),
        ("maximise", .maximize), ("maximize", .maximize),
        ("fill the screen", .maximize), ("as big as it goes", .maximize),
        ("middle", .center), ("centre", .center), ("center", .center),
        ("snap left", .left), ("snap right", .right),
        ("left", .left), ("right", .right), ("top", .top), ("bottom", .bottom),
        ("big", .maximize),
    ]

    /// Whole-token runs, for the same reason everything else here uses them:
    /// "left" lives inside "leftover" and "top" inside "laptop", and a window
    /// that flies to one side because you said "laptop" is worse than one that
    /// stays put.
    static func placement(for words: String) -> Placement? {
        let haystack = PhraseMatcher.Haystack(PhraseMatcher.normalize(words))
        guard haystack.wordCount > 0 else { return nil }
        for (phrase, placement) in table
        where PhraseMatcher.containsTokenRun(haystack, phrase) {
            return placement
        }
        return nil
    }

    // MARK: - Doing it

    enum Failure: Equatable {
        case noAccessibility
        case noWindow
        case refused

        var spoken: String {
            switch self {
            case .noAccessibility: return "I need Accessibility for that, sir."
            case .noWindow:        return "There's no window in front, sir."
            case .refused:         return "That window wouldn't move, sir."
            }
        }
    }

    @discardableResult
    static func apply(_ placement: Placement) -> Failure? {
        guard available else { return .noAccessibility }
        guard let window = focusedWindow() else { return .noWindow }

        if placement == .fullScreen { return toggleFullScreen(window) }

        // A window already in full screen ignores every position it is given,
        // so it has to come out first — otherwise "put it on the left" looks
        // like the command doing nothing at all.
        if isFullScreen(window) { _ = setFullScreen(window, false) }

        guard let current = frame(of: window) else { return .noWindow }
        let screen = screenContaining(current) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .refused }

        let target: CGRect
        if let (x, y, w, h) = placement.fractions {
            target = CGRect(x: visible.minX + visible.width * x,
                            y: visible.minY + visible.height * y,
                            width: visible.width * w,
                            height: visible.height * h)
        } else {
            // Centre: the window keeps its size, clamped to what will fit.
            let kept = CGSize(width: min(current.width, visible.width),
                              height: min(current.height, visible.height))
            target = CGRect(x: visible.midX - kept.width / 2,
                            y: visible.midY - kept.height / 2,
                            width: kept.width, height: kept.height)
        }
        return place(window, at: target) ? nil : .refused
    }

    // MARK: - Accessibility plumbing

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }

        let result = window as! AXUIElement
        AXUIElementSetMessagingTimeout(result, timeout)
        return result
    }

    /// The window's rectangle in AppKit coordinates.
    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = point(window, kAXPositionAttribute),
              let extent = size(window, kAXSizeAttribute)
        else { return nil }
        return fromAccessibility(CGRect(origin: origin, size: extent))
    }

    /// Written out per type rather than made generic.
    ///
    /// The generic version needed somewhere to put the result before it knew
    /// what shape it was, and reaching for `UnsafeMutablePointer.allocate` to
    /// get it both leaked the allocation and read it before `AXValueGetValue`
    /// had written anything. Two small functions have neither problem.
    private static func axValue(_ window: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    private static func point(_ window: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(window, attribute) else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &out) else { return nil }
        return out
    }

    private static func size(_ window: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(window, attribute) else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &out) else { return nil }
        return out
    }

    /// Position, then size, then position again.
    ///
    /// Not superstition: a window with a minimum size clamps the size it is
    /// given, and one being moved across displays clamps the position — so a
    /// single pass leaves it somewhere neither asked for. Setting the position
    /// again once the size has settled is what makes a half-screen actually
    /// land on its half.
    private static func place(_ window: AXUIElement, at rect: CGRect) -> Bool {
        let ax = toAccessibility(rect)
        var origin = ax.origin
        var wanted = ax.size

        guard let position = AXValueCreate(.cgPoint, &origin),
              let extent = AXValueCreate(.cgSize, &wanted)
        else { return false }

        let first = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        let sized = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, extent)
        _ = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)

        return first == .success || sized == .success
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                window, "AXFullScreen" as CFString, &raw) == .success,
              let value = raw as? Bool
        else { return false }
        return value
    }

    @discardableResult
    private static func setFullScreen(_ window: AXUIElement, _ on: Bool) -> Bool {
        let flag: CFBoolean = on ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(
            window, "AXFullScreen" as CFString, flag) == .success
    }

    private static func toggleFullScreen(_ window: AXUIElement) -> Failure? {
        setFullScreen(window, !isFullScreen(window)) ? nil : .refused
    }

    private static func screenContaining(_ rect: CGRect) -> NSScreen? {
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(middle) }
            ?? NSScreen.screens.max { a, b in
                a.frame.intersection(rect).area < b.frame.intersection(rect).area
            }
    }

    // MARK: - Two coordinate systems

    /// The height of the display the accessibility API measures from.
    ///
    /// AppKit puts the origin at the bottom left of the primary display with y
    /// increasing upwards; accessibility puts it at the *top* left with y
    /// increasing downwards. Everything else about the two agrees, so one
    /// subtraction converts between them — but which display's height to
    /// subtract from is not obvious: it is always the primary one, the screen
    /// whose frame starts at zero, however many others are attached.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
    }

    static func toAccessibility(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width, height: rect.height)
    }

    static func fromAccessibility(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width, height: rect.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
