import Foundation
import CoreGraphics

// The gesture recogniser, driven by a synthetic stream of hand positions. No
// camera, no Vision, no clock — every sample carries its own timestamp, so the
// awkward cases (a hand entering frame, a hand put down again, a slow drift
// across the desk) can be written out exactly and asserted on.
//
// Coordinates are in *user* space throughout: x grows as you move to your right.
// HandTracker does that flip once, when it reads the camera.

var failures = 0
func check(_ name: String, _ ok: Bool, _ note: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(note.isEmpty ? "" : "  [\(note)]")")
    if !ok { failures += 1 }
}

let fps = 20.0
let tick = 1.0 / fps

/// Runs a stream of frames through a fresh recogniser and returns what fired.
/// Each frame is a list of hand positions; an empty list means "no hands seen".
func run(_ frames: [[CGPoint]], config: GestureConfig = GestureConfig()) -> [Gesture] {
    let recognizer = GestureRecognizer()
    recognizer.config = config
    var fired: [Gesture] = []
    var t = 100.0
    for hands in frames {
        if let gesture = recognizer.feed(HandSample(time: t, hands: hands.sorted { $0.x < $1.x })) {
            fired.append(gesture)
        }
        t += tick
    }
    return fired
}

/// A hand sitting still at `at`, with a little noise — the way a real hand held
/// up in front of a camera never quite stops moving.
func hold(_ at: CGPoint, seconds: Double, jitter: CGFloat = 0.004) -> [[CGPoint]] {
    let frames = Int((seconds * fps).rounded())
    return (0..<frames).map { i in
        let wobble = jitter * CGFloat(sin(Double(i) * 1.7))
        return [CGPoint(x: at.x + wobble, y: at.y - wobble)]
    }
}

/// A hand travelling from `from` to `to` over `seconds`.
func move(_ from: CGPoint, _ to: CGPoint, seconds: Double) -> [[CGPoint]] {
    let frames = max(1, Int((seconds * fps).rounded()))
    return (1...frames).map { i in
        let f = CGFloat(i) / CGFloat(frames)
        return [CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)]
    }
}

/// Two hands, each travelling from its own start to its own end.
func move2(_ from: (CGPoint, CGPoint), _ to: (CGPoint, CGPoint), seconds: Double) -> [[CGPoint]] {
    let frames = max(1, Int((seconds * fps).rounded()))
    return (1...frames).map { i in
        let f = CGFloat(i) / CGFloat(frames)
        return [CGPoint(x: from.0.x + (to.0.x - from.0.x) * f,
                        y: from.0.y + (to.0.y - from.0.y) * f),
                CGPoint(x: from.1.x + (to.1.x - from.1.x) * f,
                        y: from.1.y + (to.1.y - from.1.y) * f)]
    }
}

func hold2(_ a: CGPoint, _ b: CGPoint, seconds: Double, jitter: CGFloat = 0.004) -> [[CGPoint]] {
    let frames = Int((seconds * fps).rounded())
    return (0..<frames).map { i in
        let wobble = jitter * CGFloat(sin(Double(i) * 1.7))
        return [CGPoint(x: a.x + wobble, y: a.y), CGPoint(x: b.x - wobble, y: b.y)]
    }
}

let mid = CGPoint(x: 0.5, y: 0.5)

print("=== the three gestures ===")

// Push your hand to your right and the desktop on the left comes over — the
// direction the trackpad already moves the row of desktops.
check("hand right -> desktop on the left",
      run(hold(mid, seconds: 0.5) + move(mid, CGPoint(x: 0.82, y: 0.5), seconds: 0.4))
        == [.desktopLeft])

check("hand left -> desktop on the right",
      run(hold(mid, seconds: 0.5) + move(mid, CGPoint(x: 0.18, y: 0.5), seconds: 0.4))
        == [.desktopRight])

check("both hands apart -> Mission Control",
      run(hold2(CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.58, y: 0.5), seconds: 0.5)
          + move2((CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.58, y: 0.5)),
                  (CGPoint(x: 0.20, y: 0.5), CGPoint(x: 0.80, y: 0.5)), seconds: 0.5))
        == [.missionControl])

print("\n=== a gesture has to be one you meant ===")

// The big one. Raising a hand into frame crosses most of the picture, and so
// does putting it down again. Measuring from a trailing position rather than
// from somewhere you stopped would make both of those a swipe.
check("a hand coming into frame from the edge isn't a swipe",
      run(move(CGPoint(x: 0.95, y: 0.1), CGPoint(x: 0.5, y: 0.5), seconds: 0.5)).isEmpty)

check("a hand dropped back out of frame isn't a swipe",
      run(hold(mid, seconds: 0.5)
          + move(mid, CGPoint(x: 0.05, y: 0.05), seconds: 0.45)).isEmpty,
      "diagonal, so neither axis dominates")

check("drifting slowly across the desk isn't a swipe",
      run(hold(mid, seconds: 0.4) + move(mid, CGPoint(x: 0.9, y: 0.5), seconds: 4.0)).isEmpty)

check("a small nudge isn't a swipe",
      run(hold(mid, seconds: 0.5) + move(mid, CGPoint(x: 0.62, y: 0.5), seconds: 0.3)).isEmpty)

check("waving upward isn't a swipe",
      run(hold(mid, seconds: 0.5) + move(mid, CGPoint(x: 0.56, y: 0.9), seconds: 0.4)).isEmpty)

check("a hand and nothing else fires nothing",
      run(hold(mid, seconds: 3.0)).isEmpty)

check("no hands at all fires nothing",
      run(Array(repeating: [], count: 60)).isEmpty)

print("\n=== two hands are not one hand ===")

// One hand sweeping past a hand resting on the desk opens the same gap as
// pulling both apart. It is not the same gesture and must not fire.
check("one hand sweeping past a resting one isn't Mission Control",
      run(hold2(CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5), seconds: 0.5)
          + move2((CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5)),
                  (CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.90, y: 0.5)), seconds: 0.5)).isEmpty)

check("bringing both hands together isn't Mission Control",
      run(hold2(CGPoint(x: 0.20, y: 0.5), CGPoint(x: 0.80, y: 0.5), seconds: 0.5)
          + move2((CGPoint(x: 0.20, y: 0.5), CGPoint(x: 0.80, y: 0.5)),
                  (CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5)), seconds: 0.5)).isEmpty)

// Raising a second hand changes the gesture, so the trail starts over rather
// than being measured against where one hand used to be. The one-handed leg
// here stays well under the travel threshold, so the only thing that could fire
// is a two-hand reading of the transition itself.
check("a second hand arriving mid-move isn't read as a pull-apart",
      run(hold(mid, seconds: 0.4)
          + move(mid, CGPoint(x: 0.60, y: 0.5), seconds: 0.2)
          + hold2(CGPoint(x: 0.60, y: 0.5), CGPoint(x: 0.78, y: 0.5), seconds: 0.25)).isEmpty)

print("\n=== one gesture at a time ===")

check("a single swipe fires exactly once",
      run(hold(mid, seconds: 0.5)
          + move(mid, CGPoint(x: 0.85, y: 0.5), seconds: 0.4)
          + hold(CGPoint(x: 0.85, y: 0.5), seconds: 1.5)).count == 1)

// Two deliberate swipes with a pause between them is two desktops over, which
// is the point of keeping the camera open after the first one.
let twice = run(hold(mid, seconds: 0.5)
                + move(mid, CGPoint(x: 0.85, y: 0.5), seconds: 0.35)
                + hold(CGPoint(x: 0.85, y: 0.5), seconds: 0.8)
                + move(CGPoint(x: 0.85, y: 0.5), CGPoint(x: 0.50, y: 0.5), seconds: 0.35)
                + hold(mid, seconds: 0.5))
check("swipe, pause, swipe back -> two gestures",
      twice == [.desktopLeft, .desktopRight], "\(twice)")

// Coming back is not a second command if it happens straight away, which is
// what the refractory period is for.
check("snapping the hand straight back doesn't fire a second time",
      run(hold(mid, seconds: 0.5)
          + move(mid, CGPoint(x: 0.85, y: 0.5), seconds: 0.35)
          + move(CGPoint(x: 0.85, y: 0.5), mid, seconds: 0.2)).count == 1)

print("\n=== a dropped frame doesn't cost you the gesture ===")

// Vision loses a hand for a frame or two against a busy background. Losing the
// anchor there would break a swipe already halfway done.
var flickery = hold(mid, seconds: 0.5)
let swipe = move(mid, CGPoint(x: 0.85, y: 0.5), seconds: 0.4)
for (i, frame) in swipe.enumerated() {
    flickery.append(i == 3 ? [] : frame)      // one frame with no hand in it
}
check("one dropped frame mid-swipe still fires", run(flickery) == [.desktopLeft])

check("a hand that comes back at the edge is arriving, not swiping",
      run(hold(mid, seconds: 0.5)
          + Array(repeating: [], count: 20)      // a whole second with no hand
          + move(CGPoint(x: 0.05, y: 0.5), CGPoint(x: 0.55, y: 0.5), seconds: 0.4)).isEmpty,
      "it comes back at the edge, so it's arriving, not swiping")

print("\n=== the two-handed gesture survives Vision losing a hand ===")

// The bug this pins down: a pull-apart heads for the edges of the frame, which
// is exactly where Vision drops a hand for a frame or two. Treating that as
// "you're now making a one-handed gesture" destroyed the anchor mid-motion,
// every time, so Mission Control could never fire at all.
var flaky = hold2(CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.58, y: 0.5), seconds: 0.5)
let apart = move2((CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.58, y: 0.5)),
                  (CGPoint(x: 0.18, y: 0.5), CGPoint(x: 0.82, y: 0.5)), seconds: 0.5)
for (i, frame) in apart.enumerated() {
    // Every third frame, one of the two hands isn't recognised.
    flaky.append(i % 3 == 1 ? [frame[1]] : frame)
}
check("Mission Control still fires when a hand flickers out", run(flaky) == [.missionControl])

// But a hand that is genuinely put down is a different gesture again. Putting
// one down costs `dropout` before the two-hand trail is given up, so the hold
// here is comfortably past it — a shorter one is the boundary case, and
// asserting on a boundary only tells you where the boundary was that day.
check("a hand gone for good doesn't leave a two-hand trail behind",
      run(hold2(CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.58, y: 0.5), seconds: 0.5)
          + hold(CGPoint(x: 0.58, y: 0.5), seconds: 1.0)
          + move(CGPoint(x: 0.58, y: 0.5), CGPoint(x: 0.20, y: 0.5), seconds: 0.4))
        == [.desktopRight],
      "it re-anchors as a one-hand gesture and swipes normally")

print("\n=== with no Accessibility, everything is Mission Control ===")

// The swipes can't do anything without Accessibility, and a two-handed
// pull-apart gets read as a one-handed swipe often enough to matter — so a
// gesture that could only have meant Mission Control would land on a no-op and
// look like the feature was broken.
check("a swipe becomes Mission Control when desktops are locked",
      Gesture.desktopLeft.action(canSwitchDesktops: false) == .missionControl)
check("and so does the other one",
      Gesture.desktopRight.action(canSwitchDesktops: false) == .missionControl)
check("Mission Control is unaffected",
      Gesture.missionControl.action(canSwitchDesktops: false) == .missionControl)

check("with Accessibility, every gesture keeps its own meaning",
      Gesture.desktopLeft.action(canSwitchDesktops: true) == .desktopLeft
      && Gesture.desktopRight.action(canSwitchDesktops: true) == .desktopRight
      && Gesture.missionControl.action(canSwitchDesktops: true) == .missionControl)

print("\n=== a gesture thrown clean off the screen still counts ===")

// Throw the gesture hard and the hands are out of shot before any frame catches
// them far enough apart. The gesture you most obviously meant was the one most
// likely to do nothing, which is a poor way for it to behave.
check("hands flung apart and out of frame fire Mission Control",
      run(hold2(CGPoint(x: 0.44, y: 0.5), CGPoint(x: 0.56, y: 0.5), seconds: 0.5)
          + move2((CGPoint(x: 0.44, y: 0.5), CGPoint(x: 0.56, y: 0.5)),
                  (CGPoint(x: 0.06, y: 0.5), CGPoint(x: 0.94, y: 0.5)), seconds: 0.2)
          + [[]])                                    // both gone
        == [.missionControl])

check("a hand flung off the left edge fires the desktop on the right",
      run(hold(mid, seconds: 0.5)
          + move(mid, CGPoint(x: 0.07, y: 0.5), seconds: 0.2)
          + [[]])
        == [.desktopRight])

// The projection is a lower bound on where a hand went, not a guess about it —
// so it must not invent motion that never happened.
check("a hand resting near the edge that blinks out fires nothing",
      run(hold(CGPoint(x: 0.06, y: 0.5), seconds: 0.8) + [[]]).isEmpty)

check("a hand that vanishes mid-frame fires nothing",
      run(hold(mid, seconds: 0.5)
          + move(mid, CGPoint(x: 0.60, y: 0.5), seconds: 0.15)
          + [[]]).isEmpty,
      "nothing to project — it stopped in open space")

check("one hand leaving while the other rests still isn't Mission Control",
      run(hold2(CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5), seconds: 0.5)
          + move2((CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.55, y: 0.5)),
                  (CGPoint(x: 0.45, y: 0.5), CGPoint(x: 0.94, y: 0.5)), seconds: 0.2)
          + [[]]).isEmpty)

print("\n=== detection that comes and goes still works ===")

// Straight from a real log: the camera reporting 1 hand, then 0, then 1, in
// bursts about a second apart. If the anchor can't survive gaps that long it is
// never held long enough to measure anything from, and nothing ever fires —
// which is exactly what "no hand held still long enough to aim from" meant.
func gappy(_ frames: [[CGPoint]], seenEvery n: Int) -> [[CGPoint]] {
    frames.enumerated().map { $0.offset % n == 0 ? $0.element : [] }
}

check("a hand seen every other frame still settles and swipes",
      run(gappy(hold(mid, seconds: 0.8), seenEvery: 2)
          + gappy(move(mid, CGPoint(x: 0.85, y: 0.5), seconds: 0.5), seenEvery: 2))
        == [.desktopLeft])

check("a hand seen every third frame still settles and swipes",
      run(gappy(hold(mid, seconds: 1.0), seenEvery: 3)
          + gappy(move(mid, CGPoint(x: 0.85, y: 0.5), seconds: 0.6), seenEvery: 3))
        == [.desktopLeft])

// Tolerating gaps must not mean tolerating absence: the jump across a long
// gap is not movement, and measuring across it would turn putting your hand
// down here and raising it there into a swipe.
check("a hand that vanishes and reappears elsewhere isn't a swipe",
      run(hold(mid, seconds: 0.6)
          + Array(repeating: [], count: 20)          // a whole second gone
          + hold(CGPoint(x: 0.85, y: 0.5), seconds: 0.6)).isEmpty,
      "the trail from before the gap is gone, so there is nothing to measure across")

print("\n=== no waiting around ===")

// The point of the rewrite. Measuring from a spot where your hands had been
// *still* meant a gesture could not begin until you had first stopped — so
// clapping and immediately pulling your hands apart was guaranteed to do
// nothing, and a gesture already under way when the camera opened was
// unrecognisable no matter how plainly you made it.
check("hands that pull apart the instant they are seen fire",
      run(move2((CGPoint(x: 0.44, y: 0.5), CGPoint(x: 0.56, y: 0.5)),
                (CGPoint(x: 0.22, y: 0.5), CGPoint(x: 0.78, y: 0.5)), seconds: 0.35))
        == [.missionControl],
      "no stillness first, no warm-up")

check("a swipe with no pause before it fires",
      run(move(mid, CGPoint(x: 0.84, y: 0.5), seconds: 0.3)) == [.desktopLeft])

// The camera opens part-way through the motion and sees only the tail of it.
check("a pull-apart already under way when the camera opens still fires",
      run(move2((CGPoint(x: 0.34, y: 0.5), CGPoint(x: 0.66, y: 0.5)),
                (CGPoint(x: 0.14, y: 0.5), CGPoint(x: 0.86, y: 0.5)), seconds: 0.25))
        == [.missionControl])

// A change in hand count used to cost the gesture that followed it its first
// `dropout` — the frames were dropped outright, and the new trail began at
// wherever the hands had got to by the time the change was believed. That is
// the worst possible case to lose, because the double clap that opens the
// camera *is* a change in hand count: hands together, then apart. Both of
// these are the same motion as the two checks above, with one hand visible
// beforehand.
check("a pull-apart right after a one-handed clap fires",
      run(hold(mid, seconds: 0.4)
          + move2((CGPoint(x: 0.44, y: 0.5), CGPoint(x: 0.56, y: 0.5)),
                  (CGPoint(x: 0.18, y: 0.5), CGPoint(x: 0.82, y: 0.5)), seconds: 0.4))
        == [.missionControl],
      "the trail starts where the second hand appeared, not half a second later")

check("a swipe right after two hands were up fires",
      run(hold2(CGPoint(x: 0.44, y: 0.5), CGPoint(x: 0.56, y: 0.5), seconds: 0.4)
          + move(CGPoint(x: 0.50, y: 0.5), CGPoint(x: 0.86, y: 0.5), seconds: 0.4))
        == [.desktopLeft])

print("\n=== it says why it didn't fire ===")
let quiet = GestureRecognizer()
var qt = 100.0
for _ in 0..<30 { _ = quiet.feed(HandSample(time: qt, hands: [])); qt += tick }
check("a camera that never found a hand says so",
      quiet.diagnosis.contains("never found a hand"), quiet.diagnosis)

let short = GestureRecognizer()
var st = 100.0
for hands in hold(mid, seconds: 0.5) + move(mid, CGPoint(x: 0.62, y: 0.5), seconds: 0.3) {
    _ = short.feed(HandSample(time: st, hands: hands)); st += tick
}
check("a swipe that fell short reports how far it got",
      short.sawHand && short.peakTravel > 0.05 && short.peakTravel < 0.18,
      short.diagnosis)

print("\n=== reset clears everything ===")
let recognizer = GestureRecognizer()
var t = 100.0
for hands in hold(mid, seconds: 0.5) {
    _ = recognizer.feed(HandSample(time: t, hands: hands)); t += tick
}
recognizer.reset()
var afterReset: [Gesture] = []
for hands in move(CGPoint(x: 0.04, y: 0.5), CGPoint(x: 0.54, y: 0.5), seconds: 0.4) {
    if let g = recognizer.feed(HandSample(time: t, hands: hands)) { afterReset.append(g) }
    t += tick
}
check("a swipe measured from a cleared trail doesn't fire", afterReset.isEmpty,
      "this is what muting the camera while you talk relies on")

print(failures == 0 ? "\nALL GESTURE TESTS PASSED" : "\n\(failures) GESTURE TESTS FAILED")
exit(failures == 0 ? 0 : 1)
