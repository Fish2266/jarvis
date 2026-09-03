import Foundation
import CoreGraphics

/// The three things the camera can be asked for.
///
/// Deliberately coarse. A gesture has to beat the microphone to the punch and
/// then move your whole desktop, so it has to be something you could only have
/// meant on purpose — there is no vocabulary of small precise signs here, and
/// adding one would mostly add ways to trigger the wrong thing.
enum Gesture: Equatable {
    /// Both hands pulled apart.
    case missionControl
    /// Hand pushed to your right — the desktop on the left comes over.
    case desktopLeft
    /// Hand pulled to your left — the desktop on the right comes over.
    case desktopRight
}

extension Gesture {
    /// What this gesture can actually do, given whether desktops can be switched.
    ///
    /// Without Accessibility the two swipes do nothing at all, and a two-handed
    /// pull-apart is misread as a one-handed swipe often enough to matter — so a
    /// gesture that could only have meant Mission Control would land on a no-op
    /// and look like the whole feature was broken. Mission Control is the one
    /// thing that works with nothing granted, so with the swipes unavailable
    /// every gesture goes there instead. Better one gesture that always works
    /// than three where two are silent.
    func action(canSwitchDesktops: Bool) -> Gesture {
        canSwitchDesktops ? self : .missionControl
    }
}

/// One camera frame's worth of hands, already in *user* space: x grows as you
/// move to your right, y grows as you move up, both 0-1 across the frame.
///
/// Sorted left to right by the caller, so the two entries keep meaning the same
/// two hands from frame to frame — Vision has no obligation to return them in a
/// stable order, and a swap mid-gesture would read as both hands teleporting.
struct HandSample: Equatable {
    var time: Double
    var hands: [CGPoint]
}

struct GestureConfig {
    /// How far one hand must travel, as a fraction of the frame width.
    var travel: CGFloat = 0.18
    /// How much further apart two hands must get.
    var spread: CGFloat = 0.15
    /// A swipe is sideways: the horizontal move must beat the vertical one by
    /// this much, so reaching for your coffee isn't a command.
    var axisRatio: CGFloat = 1.6
    /// The smaller share of a pull-apart each hand must contribute. One hand
    /// sweeping past a hand resting on the desk opens the same gap, and isn't
    /// the same gesture.
    var symmetry: CGFloat = 0.18
    /// The longest span of time a single gesture may be measured across.
    /// Slower than this is repositioning, not a gesture.
    var maxDuration: Double = 1.2
    /// How much history is kept. A little longer than `maxDuration`, so the
    /// oldest usable start is still in hand when it's needed.
    var window: Double = 1.4
    /// A hand may go unseen for this long without the trail being cut.
    var dropout: Double = 0.45
    /// Ignore everything for this long after a gesture fires.
    var refractory: Double = 0.55
    /// How close to the edge of the frame counts as being at it.
    var edge: CGFloat = 0.12
    /// How long a hand that arrived at the edge of the frame is presumed to
    /// still be arriving.
    var entryGrace: Double = 0.35
    /// Fewest frames a gesture may be measured from. Two points and a straight
    /// line is what a single mis-detection looks like.
    var minSamples: Int = 3
    /// How many frames in a row a changed hand count must hold before it is
    /// believed rather than treated as Vision blinking. Counted in frames, not
    /// seconds, because that is what the flicker is measured in: Vision drops
    /// one of two hands for a frame or two at a time, and four in a row is not
    /// something it does. At 30 fps this is an eighth of a second.
    var changeSamples: Int = 4
}

/// Turns a stream of hand positions into at most one gesture at a time.
///
/// It keeps a short trail of where your hands have been and, on every frame,
/// asks one question: is there any moment in the last second or so that, paired
/// with right now, makes a gesture? That is the whole design, and it is a
/// deliberate replacement for what came before.
///
/// The previous version measured from an *anchor*: a spot where your hands had
/// been still for a moment. It was accurate and far too slow. It meant a gesture
/// could never begin until you had first stopped, so clapping and immediately
/// pulling your hands apart was guaranteed to do nothing — and worse, if the
/// camera opened while you were already moving, there was no still moment left
/// to find and the gesture was unrecognisable no matter how plainly you made it.
///
/// Searching the trail instead costs a scan of a few dozen points per frame and
/// removes the wait entirely. What the anchor was really protecting against —
/// a hand crossing half the frame on its way *in* reading as a swipe — is
/// handled directly by `entryGrace` instead, and only in the case it applies to.
///
/// No Vision, no AVFoundation, no clock of its own: every input arrives with its
/// own timestamp, so the whole thing runs offline against a synthetic stream in
/// Tests/gestures.
final class GestureRecognizer {

    var config = GestureConfig()

    private struct Frame {
        var time: Double
        var hands: [CGPoint]
    }

    private var trail: [Frame] = []
    /// Frames whose hand count disagrees with the trail's, held back until the
    /// disagreement proves to be a real change rather than Vision blinking.
    private var pending: [Frame] = []
    private var mutedUntil: Double = -.greatestFiniteMagnitude
    /// When the current run of this-many-hands began, and whether it began with
    /// a hand at the edge of the frame — which is what "walking into shot"
    /// looks like, and the one thing that must not read as a swipe.
    private var presenceStart: Double = -.greatestFiniteMagnitude
    private var enteredFromEdge = false

    // Why nothing fired, for the Clap Monitor. "It didn't work" is not something
    // you can debug standing in front of a camera with both hands up.
    private(set) var sawHand = false
    private(set) var sawTwoHands = false
    private(set) var peakTravel: CGFloat = 0
    private(set) var peakSpread: CGFloat = 0

    func reset() {
        trail.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        mutedUntil = -.greatestFiniteMagnitude
        presenceStart = -.greatestFiniteMagnitude
        enteredFromEdge = false
        sawHand = false
        sawTwoHands = false
        peakTravel = 0
        peakSpread = 0
    }

    /// One line saying how close you got.
    var diagnosis: String {
        guard sawHand else { return "the camera never found a hand" }
        var parts: [String] = []
        if peakTravel > 0 {
            parts.append(String(format: "furthest one-hand move %.2f (needs %.2f)",
                                peakTravel, config.travel))
        }
        parts.append(sawTwoHands
            ? String(format: "widest two-hand spread %.2f (needs %.2f)", peakSpread, config.spread)
            : "never saw two hands at once")
        return parts.joined(separator: ", ")
    }

    /// Feeds one frame. Returns a gesture on the frame that completes it.
    func feed(_ sample: HandSample) -> Gesture? {
        let now = sample.time

        guard now >= mutedUntil else {
            trail.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            return nil
        }

        var promoted = false
        let count = sample.hands.count
        if count >= 1 { sawHand = true }
        if count == 2 { sawTwoHands = true }

        guard count == 1 || count == 2 else {
            // Hands gone. If they went off the side of the picture while moving,
            // that is the answer rather than something to wait out.
            if let gesture = completeAtEdge(now: now) { return fire(gesture, at: now) }
            if let last = trail.last, now - last.time > config.dropout {
                trail.removeAll(keepingCapacity: true)
                pending.removeAll(keepingCapacity: true)
                presenceStart = -.greatestFiniteMagnitude
            }
            return nil
        }

        // A change in how many hands are up means a different gesture, but only
        // once it sticks: Vision drops one of two hands constantly, and treating
        // the first mismatched frame as a new gesture threw away the trail in
        // the middle of every pull-apart.
        //
        // Waiting is not the same as not looking, though. These frames are held
        // rather than dropped, so that when the change does stick the new trail
        // begins at the frame the count first changed on — not at wherever the
        // hands have got to by the time it is believed, with the opening of the
        // gesture already spent. That used to cost every gesture following a
        // change in hand count its first half-second, and the double clap that
        // opens the camera is itself such a change: hands together, then apart.
        // A brisk pull-apart straight after a clap therefore did nothing at all.
        if let last = trail.last {
            if last.hands.count != count {
                if let gesture = completeAtEdge(now: now) { return fire(gesture, at: now) }
                hold(sample.hands, at: now)
                guard pending.count >= config.changeSamples else { return nil }
                promotePending()
                promoted = true
            } else {
                // The old count came back, so the disagreement was a blink.
                pending.removeAll(keepingCapacity: true)
            }
        } else {
            beginPresence(sample.hands, at: now)
        }

        // Promotion adopts the held frames wholesale, and this frame is the last
        // of them — so it is already in the trail and must not go in twice.
        if !promoted { trail.append(Frame(time: now, hands: sample.hands)) }
        prune(before: now - config.window)

        guard let gesture = classify(now: sample.hands, at: now) else { return nil }
        return fire(gesture, at: now)
    }

    // MARK: - Trail

    private func beginPresence(_ hands: [CGPoint], at time: Double) {
        trail.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        presenceStart = time
        // If a hand is at the edge the moment it appears, it is on its way in.
        // If it appears in open frame — because it was already up when the
        // camera opened — there is nothing to wait for.
        enteredFromEdge = hands.contains { $0.x <= config.edge || $0.x >= 1 - config.edge }
    }

    /// Keeps a frame that disagrees with the trail, in case the disagreement
    /// turns out to be real. A second change of count abandons the first.
    private func hold(_ hands: [CGPoint], at time: Double) {
        if pending.last?.hands.count != hands.count {
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(Frame(time: time, hands: hands))
    }

    /// The hand count really did change. Adopt the held frames as the new trail,
    /// so the gesture is measured from the frame the change began on rather than
    /// from the one it was finally believed on.
    private func promotePending() {
        guard let start = pending.first else { return }
        let buffered = pending
        beginPresence(start.hands, at: start.time)   // clears trail and pending
        trail = buffered
    }

    private func prune(before cutoff: Double) {
        guard let first = trail.first, first.time < cutoff else { return }
        var drop = 0
        while drop < trail.count, trail[drop].time < cutoff { drop += 1 }
        trail.removeFirst(drop)
    }

    private func fire(_ gesture: Gesture, at now: Double) -> Gesture {
        trail.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        presenceStart = -.greatestFiniteMagnitude
        mutedUntil = now + config.refractory
        return gesture
    }

    /// Whether a frame is old enough to be measured from.
    ///
    /// Only bites when the hand arrived at the edge of the frame. A hand that
    /// appeared in open frame is measurable from the instant it is seen, which
    /// is what lets a gesture already in progress when the camera opens still
    /// land.
    private func usableStart(_ frame: Frame, now: Double) -> Bool {
        guard now - frame.time <= config.maxDuration else { return false }
        guard enteredFromEdge else { return true }
        return frame.time - presenceStart >= config.entryGrace
    }

    // MARK: - Deciding

    /// Looks for any moment in the trail that, paired with now, is a gesture.
    private func classify(now hands: [CGPoint], at time: Double) -> Gesture? {
        guard let start = bestStart(now: hands, at: time) else { return nil }
        return decide(from: start, to: hands)
    }

    /// The moment in the trail that `hands` has moved furthest from.
    ///
    /// Picking the extreme rather than the oldest is what makes this robust to a
    /// gesture that starts mid-trail: the frames before you began moving simply
    /// lose to the ones after.
    private func bestStart(now hands: [CGPoint], at time: Double) -> [CGPoint]? {
        var best: [CGPoint]?
        var bestScore: CGFloat = 0
        var usable = 0

        for frame in trail where frame.hands.count == hands.count {
            guard usableStart(frame, now: time) else { continue }
            usable += 1
            let score: CGFloat = hands.count == 2
                ? (hands[1].x - hands[0].x) - (frame.hands[1].x - frame.hands[0].x)
                : abs(hands[0].x - frame.hands[0].x)
            if score > bestScore {
                bestScore = score
                best = frame.hands
            }
        }

        guard usable >= config.minSamples else { return nil }
        if let best { note(from: best, to: hands) }
        return best
    }

    private func decide(from rest: [CGPoint], to hands: [CGPoint]) -> Gesture? {
        guard rest.count == hands.count else { return nil }

        if rest.count == 2 {
            let opened = (hands[1].x - hands[0].x) - (rest[1].x - rest[0].x)
            guard opened >= config.spread else { return nil }
            let leftMoved = rest[0].x - hands[0].x        // left hand, further left
            let rightMoved = hands[1].x - rest[1].x       // right hand, further right
            guard min(leftMoved, rightMoved) >= opened * config.symmetry else { return nil }
            return .missionControl
        }

        let dx = hands[0].x - rest[0].x
        let dy = hands[0].y - rest[0].y
        guard abs(dx) >= config.travel, abs(dx) >= config.axisRatio * abs(dy) else { return nil }
        // Push right and the desktop on the left comes over: your hand drags the
        // row of desktops past you, which is the direction the trackpad's
        // three-finger swipe already moves them.
        return dx > 0 ? .desktopLeft : .desktopRight
    }

    /// Finishes a gesture whose hands ran off the side of the picture.
    ///
    /// Only the hands that were *at* the edge are moved, and only as far as the
    /// edge itself — a lower bound on where they actually went, not a guess
    /// about it. Everything else still has to pass the same thresholds, so a
    /// hand resting near the edge and blinking out fires nothing.
    private func completeAtEdge(now: Double) -> Gesture? {
        guard let last = trail.last, now - last.time <= config.dropout else { return nil }

        let projected = last.hands.map { hand -> CGPoint in
            if hand.x <= config.edge { return CGPoint(x: 0, y: hand.y) }
            if hand.x >= 1 - config.edge { return CGPoint(x: 1, y: hand.y) }
            return hand
        }
        guard projected != last.hands else { return nil }
        guard let start = bestStart(now: projected, at: last.time) else { return nil }
        return decide(from: start, to: projected)
    }

    /// Records how far this attempt got, so a gesture that never fires can say
    /// what it was short of rather than nothing at all.
    private func note(from rest: [CGPoint], to hands: [CGPoint]) {
        guard rest.count == hands.count else { return }
        if rest.count == 2 {
            peakSpread = max(peakSpread,
                             (hands[1].x - hands[0].x) - (rest[1].x - rest[0].x))
        } else {
            peakTravel = max(peakTravel, abs(hands[0].x - rest[0].x))
        }
    }
}
