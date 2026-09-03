import AVFoundation
import Vision
import CoreImage
import CoreGraphics

/// The camera half of the trigger: opened by a double clap, shut the moment the
/// phrase resolves or the window runs out.
///
/// The session is built the first time it's needed and then kept. Configuring
/// one costs the better part of a second, and that second would come out of the
/// few you have to actually gesture in. A configured session is not a running
/// one — no frames are delivered and the camera light stays off until
/// `start()`, which is the whole point of the feature being clap-gated.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// All three fire on the main queue.
    var onGesture: ((Gesture) -> Void)?
    var onLog: ((String) -> Void)?
    /// Fires when frames actually start arriving, which is not when `start()`
    /// was called — opening a camera for the first time can take seconds.
    var onReady: (() -> Void)?
    /// Only ever called while `wantsPreview` is set — converting a frame for
    /// display is real work, and the Clap Monitor is usually shut.
    var onPreview: ((CGImage?, [CameraPreviewView.Hand], String) -> Void)?

    /// Vision looks at every frame the camera sends.
    ///
    /// This used to skip a third of them, on the reasoning that a swipe lasts a
    /// third of a second and twenty samples a second is plenty. It isn't, for
    /// the fast ones: fling a gesture and it is over in a couple of hundred
    /// milliseconds, and the frames thrown away are exactly the ones that would
    /// have caught it. The camera is pinned to 30 fps, so this ceiling just has
    /// to sit above it.
    private static let analysisInterval: CFAbsoluteTime = 0.028

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.connorchristopherson.Jarvis.hands")
    private let recognizer = GestureRecognizer()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// Main-queue only.
    private(set) var isRunning = false

    // Everything below is touched only on `queue`.
    private var configured = false
    private var capturing = false
    private var mutedUntil: CFAbsoluteTime = 0
    private var lastAnalysis: CFAbsoluteTime = 0
    private var lastCount = -1
    private var lastCountReport: CFAbsoluteTime = 0
    private var previewing = false
    private var lastPreview: CFAbsoluteTime = 0

    /// The preview is for a human watching a window, not for the recogniser.
    /// Fifteen a second looks perfectly smooth and halves the scaling and
    /// colour-conversion work of matching the analysis rate.
    private static let previewInterval: CFAbsoluteTime = 1.0 / 15.0

    // MARK: - Permission

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static var authorized: Bool { authorization == .authorized }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    // MARK: - Run loop

    func start() {
        guard !isRunning, Self.authorized else { return }
        isRunning = true
        // startRunning blocks for as long as the camera takes to wake, which is
        // not something to do on the main thread while a HUD is animating.
        queue.async { [weak self] in
            guard let self else { return }
            self.recognizer.reset()
            self.mutedUntil = 0
            self.lastAnalysis = 0
            self.lastPreview = 0
            self.lastCount = -1
            self.lastCountReport = 0
            if self.previewing {
                DispatchQueue.main.async { self.onPreview?(nil, [], "Camera starting…") }
            }
            guard self.configure() else {
                self.report("couldn't open the camera — gestures are off for this one")
                DispatchQueue.main.async { self.isRunning = false }
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.capturing = true
            DispatchQueue.main.async { [weak self] in self?.onReady?() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            if self.session.isRunning { self.session.stopRunning() }
            // Say how close it got before forgetting. Standing in front of a
            // camera with both hands up is no place to debug "nothing happened".
            self.report("gestures: \(self.recognizer.diagnosis)")
            self.recognizer.reset()
            self.lastCount = -1
        }
    }

    /// Turns the preview feed on and off. Same bargain as the level meter: the
    /// work only happens while something is on screen to show it.
    func wantsPreview(_ wanted: Bool) {
        queue.async { [weak self] in self?.previewing = wanted }
    }

    /// Holds the camera off while a phrase is being spoken.
    ///
    /// Frames are dropped without being analysed, so talking costs nothing, and
    /// the recogniser is reset so a hand that was moving across the boundary
    /// can't come back and complete a gesture out of two unrelated halves.
    func mute(for seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.mutedUntil = max(self.mutedUntil, CFAbsoluteTimeGetCurrent() + seconds)
            self.recognizer.reset()
        }
    }

    // MARK: - Capture

    private func configure() -> Bool {
        guard !configured else { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        session.beginConfiguration()
        // No session preset: the device format is chosen explicitly below, and
        // on macOS that is what wins. (`.inputPriority`, the iOS way of saying
        // "leave the format alone", doesn't exist here.)

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        configure(device)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    Int(kCVPixelFormatType_32BGRA)]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)

        // Whether a Mac hands you a mirrored picture of yourself is not
        // something to leave to the default: get it wrong and every gesture
        // works perfectly in the wrong direction. Pin it, and `user(_:)` inside
        // `read(_:joints:)` does the one flip that turns the camera's view into
        // yours.
        if let connection = output.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        session.commitConfiguration()
        configured = true
        report("camera configured: \(device.localizedName)")
        return true
    }

    /// Picks the format that sees the most of you, and pins the frame rate.
    ///
    /// **The format.** macOS doesn't publish a field of view per format, but the
    /// shape gives it away: on Apple's built-in cameras the 16:9 modes are a
    /// vertical crop of the same sensor readout the 4:3 modes use whole. This
    /// FaceTime camera offers 1920x1080 and 1760x1328 — the same horizontal
    /// field, and about a quarter more of you vertically in the second one. Since the
    /// commonest way to lose a gesture is a hand leaving the top or bottom of
    /// the picture, the squarer format is strictly the better one, so the pick
    /// is: landscape, fast enough, and whatever shape is nearest 4:3.
    ///
    /// **The frame rate.** Left alone, a webcam in a dim room lengthens its
    /// exposure and drops its rate, and a hand moving through a 1/8-second
    /// exposure arrives as a smear with no skeleton in it — so detection fails
    /// exactly while you are gesturing. Pinning the duration caps the exposure
    /// with it. A darker, sharper frame is the trade, and it is the right way
    /// round for this.
    private func configure(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if let format = Self.widestFormat(of: device) {
            device.activeFormat = format
        }
        // After the format, never before: setting a format resets these.
        let wanted = CMTime(value: 1, timescale: 30)
        if device.activeFormat.videoSupportedFrameRateRanges
            .contains(where: { $0.maxFrameRate >= 30 && $0.minFrameRate <= 30 }) {
            device.activeVideoMinFrameDuration = wanted
            device.activeVideoMaxFrameDuration = wanted
        }
    }

    private static func widestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestScore = CGFloat.greatestFiniteMagnitude
        var bestPixels = 0

        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.width >= size.height else { continue }        // never portrait
            guard format.videoSupportedFrameRateRanges
                    .contains(where: { $0.maxFrameRate >= 30 }) else { continue }

            let shape = abs(CGFloat(size.width) / CGFloat(size.height) - 4.0 / 3.0)
            let pixels = Int(size.width) * Int(size.height)
            // Nearest to 4:3 wins; the more detailed one breaks a tie, because
            // a hand at arm's length is not many pixels to find a skeleton in.
            if shape < bestScore - 0.01 || (abs(shape - bestScore) <= 0.01 && pixels > bestPixels) {
                bestScore = min(bestScore, shape)
                bestPixels = pixels
                best = format
            }
        }
        return best
    }

    /// Builds the capture session without starting it.
    ///
    /// Configuring is not capturing: no frames are delivered and the camera
    /// indicator stays dark until `start()`. Doing it up front costs nothing
    /// and takes the several-second first-open out of the few seconds you have
    /// to actually gesture in.
    func prepare() {
        guard Self.authorized else { return }
        queue.async { [weak self] in _ = self?.configure() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard capturing else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysis >= Self.analysisInterval else { return }
        lastAnalysis = now

        // Muted means the recogniser gets nothing, not that the preview goes
        // dark: "is it even pointed at me" is the first thing you want to know,
        // and you want to know it while you're talking too. But there is no
        // point looking for hands nobody will be shown and nothing will act on,
        // so while muted this does the cheap half only.
        let muted = now < mutedUntil
        let wantsFrame = previewing && now - lastPreview >= Self.previewInterval
        guard !muted || wantsFrame else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if muted {
            lastPreview = now
            let image = previewImage(from: pixels)
            DispatchQueue.main.async { [weak self] in
                self?.onPreview?(image, [], "muted — listening to you instead")
            }
            return
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        // Assembling the skeleton is only worth it when something is going to
        // draw it, and only as often as a person can see.
        let readings = (request.results ?? []).map { Self.read($0, joints: wantsFrame) }
        let hands = readings.compactMap(\.centre).sorted { $0.x < $1.x }

        if wantsFrame {
            lastPreview = now
            let image = previewImage(from: pixels)
            let drawn = readings.map {
                CameraPreviewView.Hand(joints: $0.joints, centre: $0.centre)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onPreview?(image, drawn,
                                 "\(hands.count) of \(readings.count) hand(s) usable")
            }
        }

        // Whether the camera can see you at all is the first thing you want to
        // know, and the only way to find out is to be told. Reporting what
        // Vision found *and* what survived matters: "found 2, kept 0" is a
        // confidence problem, "found 0" is a lighting or framing problem, and
        // they have nothing to do with each other. Throttled, because the count
        // flickers and this is a log, not a meter.
        if hands.count != lastCount, now - lastCountReport > 0.4 {
            lastCount = hands.count
            lastCountReport = now
            report(hands.count == readings.count
                   ? "camera sees \(hands.count) hand\(hands.count == 1 ? "" : "s")"
                   : "camera sees \(hands.count) usable of \(readings.count) found")
        }

        guard let gesture = recognizer.feed(HandSample(time: now, hands: hands)) else { return }
        DispatchQueue.main.async { [weak self] in self?.onGesture?(gesture) }
    }

    /// Where a hand *is*, in user space, plus everything Vision recognised of
    /// it so the preview can draw the same hand the recogniser is measuring.
    ///
    /// The knuckles averaged together rather than the wrist alone: the wrist
    /// point swings about as the hand rotates, and a position that jitters needs
    /// a larger movement threshold to stay quiet — which makes for a worse
    /// gesture. Two joints have to be confident, so a hand seen as a single
    /// fingertip doesn't contribute a position invented from nothing.
    private static func read(_ observation: VNHumanHandPoseObservation, joints wantJoints: Bool)
        -> (centre: CGPoint?, joints: [CGPoint]) {

        // Vision reports the camera's picture of you; you think in terms of your
        // own left and right. This flip is the only place that knows which way
        // round the frame is — everything downstream is in your terms.
        func user(_ p: CGPoint) -> CGPoint { CGPoint(x: 1 - p.x, y: p.y) }

        let all = (try? observation.recognizedPoints(.all)) ?? [:]
        var joints: [CGPoint] = []
        if wantJoints { joints.reserveCapacity(all.count) }
        // The fallback centroid is accumulated in the same pass rather than
        // collected and reduced: this runs thirty times a second per hand.
        var looseX: CGFloat = 0, looseY: CGFloat = 0, loose = 0
        for point in all.values where point.confidence > 0.2 {
            let p = user(point.location)
            looseX += p.x
            looseY += p.y
            loose += 1
            if wantJoints { joints.append(p) }
        }

        let anchors: [VNHumanHandPoseObservation.JointName] =
            [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP, .thumbCMC]
        var x: CGFloat = 0, y: CGFloat = 0, seen: CGFloat = 0
        for name in anchors {
            guard let point = all[name], point.confidence > 0.25 else { continue }
            x += point.location.x
            y += point.location.y
            seen += 1
        }
        if seen >= 2 { return (user(CGPoint(x: x / seen, y: y / seen)), joints) }

        // Failing that, the average of whatever Vision *did* see.
        //
        // The knuckles are the better anchor because they barely move as the
        // fingers open and close — but a stable position you don't have is
        // worth nothing, and a hand held at an angle or caught mid-swipe loses
        // exactly those joints while the fingers stay perfectly visible. A
        // centroid that wanders a few percent as the fingers move is nothing
        // against a threshold of a fifth of the frame.
        guard loose >= 5 else { return (nil, joints) }
        return (CGPoint(x: looseX / CGFloat(loose), y: looseY / CGFloat(loose)), joints)
    }

    /// A small copy of the frame for the monitor. Scaled down hard: this is a
    /// thumbnail to sanity-check framing against, not a viewfinder.
    private func previewImage(from pixels: CVPixelBuffer) -> CGImage? {
        let full = CIImage(cvPixelBuffer: pixels)
        guard full.extent.width > 0 else { return nil }
        let scale = 400 / full.extent.width
        let small = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(small, from: small.extent)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }
}
