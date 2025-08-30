import UIKit
import AVFoundation
import Vision
import CoreHaptics
import CoreVideo

final class LiveCameraUIView: UIView {

    // MARK: Camera
    private let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.video.queue", qos: .userInitiated)
    private var preview: AVCaptureVideoPreviewLayer!

    // MARK: Track (one per number)
    private struct Track {
        let number: String
        var observation: VNDetectedObjectObservation
        var request: VNTrackObjectRequest
        weak var tagLayer: CALayer?
        var lastSeen: Date
        var hits: Int
        var misses: Int          // NEW: consecutive bad/empty frames
        var locked: Bool
    }

    private let syncQ = DispatchQueue(label: "tracks.sync", attributes: .concurrent)
    private var _tracks: [String: Track] = [:]               // keyed by number
    private var tracks: [String: Track] {
        get { syncQ.sync { _tracks } }
        set { syncQ.async(flags: .barrier) { self._tracks = newValue } }
    }

    // MARK: Public API
    var numbersToMatch: Set<String> = []     // empty = accept any 4–6 digit
    var collectedNumbers = Set<String>()
    var onNumberCollected: ((String) -> Void)?
    var onDebugUpdate: ((String) -> Void)?
    var isScanning = true { didSet { if !isScanning { clearAllTags() } } }

    // MARK: Haptics
    private var engine: CHHapticEngine?
    private var lastHaptic = Date()
    private let hapticDebounce: TimeInterval = 0.5
    public var hapticEngine: CHHapticEngine? { get { engine } set { engine = newValue; try? engine?.start() } }

    // MARK: Tuning
    private var frameIndex = 0
    private let ocrEveryN = 2
    private let lockHits = 3
    private let timeout: TimeInterval = 0.35        // expire quickly when unseen
    private let minTrackConfidence: Float = 0.55    // NEW: only “good” tracker updates count
    private let maxMissFrames = 6                   // NEW: consecutive misses before removal
    private let smoothing: CGFloat = 0.80
    private let buttonAreaHeight: CGFloat = 220

    // OCR tuning
    private let minTextHeight: Float = 0.02
    private let useLeftStripROI: Bool = false
    private let leftStripROI = CGRect(x: 0.0, y: 0.0, width: 0.25, height: 1.0)

    // 4–6 digits
    private let minDigits = 4
    private let maxDigits = 6
    private lazy var idRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "\\d{\(minDigits),\(maxDigits)}")

    // Tag style (small red pill, modern sharp font)
    private let tagFontSize: CGFloat = 17

    // MARK: Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera(); prepareHaptics()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera(); prepareHaptics()
    }
    deinit { session.stopRunning() }

    // MARK: Camera setup
    private func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input  = try? AVCaptureDeviceInput(device: device) else { return }

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
            device.unlockForConfiguration()
        } catch { print("Device config error: \(error)") }

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.canAddInput(input) { session.addInput(input) }

        videoOut.setSampleBufferDelegate(self, queue: queue)
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = false
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }

        // Capture stays landscape (0°) for Vision
        if let c = videoOut.connection(with: .video) {
            if c.isVideoRotationAngleSupported(0.0) { c.videoRotationAngle = 0.0 }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }

        session.commitConfiguration()

        // Portrait preview for the user (90°)
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        layer.addSublayer(preview)
        if let c = preview.connection, c.isVideoRotationAngleSupported(90.0) { c.videoRotationAngle = 90.0 }

        DispatchQueue.global(qos: .userInteractive).async { self.session.startRunning() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview?.frame = bounds
        if let c = preview?.connection, c.isVideoRotationAngleSupported(90.0) { c.videoRotationAngle = 90.0 }
    }

    // MARK: Orientation mapping
    private func visionOrientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
        let angle = Int(connection.videoRotationAngle) % 360
        switch angle {
        case 0:   return .up
        case 90:  return .right
        case 180: return .down
        case 270: return .left
        default:  return .up
        }
    }

    // MARK: Geometry
    private func visionToPreviewRect(_ v: CGRect) -> CGRect {
        var r = v
        r.origin.y = 1 - r.origin.y - r.height // Vision BL → preview TL
        return preview.layerRectConverted(fromMetadataOutputRect: r)
    }
    private func rectCenter(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func pixelAlign(_ p: CGPoint) -> CGPoint { CGPoint(x: round(p.x), y: round(p.y)) }

    // MARK: Tag drawing
    private func tagSize(for number: String) -> CGSize {
        let charW: CGFloat = 10.5
        let padding: CGFloat = 16
        let w = max(44, CGFloat(number.count) * charW + padding)
        return CGSize(width: w, height: 24)
    }
    private func ensureTag(for number: String, at center: CGPoint) {
        let existing = syncQ.sync { _tracks[number]?.tagLayer }

        if let layer = existing {
            let cur = layer.position, s = smoothing
            let smoothed = CGPoint(x: cur.x * s + center.x * (1 - s),
                                   y: cur.y * s + center.y * (1 - s))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.position = pixelAlign(smoothed)
            CATransaction.commit()
            return
        }

        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: .init(width: 1, height: 1))
        container.position = pixelAlign(center)
        container.zPosition = 999

        let label = CATextLayer()
        label.string = number
        label.font = UIFont.systemFont(ofSize: tagFontSize, weight: .semibold)
        label.fontSize = tagFontSize
        label.alignmentMode = .center
        label.foregroundColor = UIColor.white.cgColor
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.96).cgColor
        label.cornerRadius = 8
        label.contentsScale = UIScreen.main.scale
        label.isWrapped = false
        label.truncationMode = .end
        label.bounds = CGRect(origin: .zero, size: tagSize(for: number))
        label.position = .zero

        container.addSublayer(label)
        preview.addSublayer(container)

        syncQ.async(flags: .barrier) {
            if var t = self._tracks[number] { t.tagLayer = container; self._tracks[number] = t }
        }
    }

    private func clearAllTags() {
        let layers = syncQ.sync { _tracks.values.compactMap { $0.tagLayer } }
        layers.forEach { $0.removeFromSuperlayer() }
        tracks = [:]
    }

    // MARK: Haptics
    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if engine == nil { engine = try? CHHapticEngine() }
        try? engine?.start()
    }
    private func haptic() {
        guard Date().timeIntervalSince(lastHaptic) > hapticDebounce else { return }
        lastHaptic = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Track upsert (per number)
    private func upsertTrack(number: String, normRect: CGRect) {
        let det = VNDetectedObjectObservation(boundingBox: normRect)

        syncQ.async(flags: .barrier) {
            if var t = self._tracks[number] {
                t.observation = det
                t.request.inputObservation = det
                t.lastSeen = Date()
                t.misses = 0                       // RESET on OCR hit
                self._tracks[number] = t
            } else {
                let req = VNTrackObjectRequest(detectedObjectObservation: det)
                req.trackingLevel = .accurate
                let track = Track(number: number, observation: det, request: req,
                                  tagLayer: nil, lastSeen: Date(), hits: 1, misses: 0, locked: false)
                self._tracks[number] = track
            }
        }
    }

    private func cleanupOldTracks(now: Date) {
        var toRemove: [String] = []
        syncQ.sync {
            for (num, t) in _tracks where t.misses >= maxMissFrames || now.timeIntervalSince(t.lastSeen) > timeout {
                toRemove.append(num)
            }
        }
        guard !toRemove.isEmpty else { return }
        DispatchQueue.main.async {
            let layers = self.syncQ.sync { toRemove.compactMap { self._tracks[$0]?.tagLayer } }
            layers.forEach { $0.removeFromSuperlayer() }
        }
        syncQ.async(flags: .barrier) { toRemove.forEach { self._tracks.removeValue(forKey: $0) } }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension LiveCameraUIView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard isScanning, let pixel = CMSampleBufferGetImageBuffer(sb) else { return }
        frameIndex += 1

        if c.isVideoRotationAngleSupported(0.0) { c.videoRotationAngle = 0.0 }
        let orientation = visionOrientation(for: c)
        let now = Date()

        // 1) Run trackers every frame (confidence-gated)
        let requests: [String: VNTrackObjectRequest] = syncQ.sync {
            Dictionary(uniqueKeysWithValues: _tracks.map { ($0.key, $0.value.request) })
        }
        if !requests.isEmpty {
            do {
                try VNSequenceRequestHandler().perform(Array(requests.values), on: pixel, orientation: orientation)

                syncQ.async(flags: .barrier) {
                    var updates: [(String, VNDetectedObjectObservation)] = []
                    for (num, var t) in self._tracks {
                        if let obs = t.request.results?.first as? VNDetectedObjectObservation,
                           obs.confidence >= self.minTrackConfidence {
                            // Good tracker frame
                            t.observation = obs
                            t.lastSeen = now
                            t.misses = 0
                            if t.hits < self.lockHits { t.hits += 1 }
                            if t.hits >= self.lockHits { t.locked = true }
                            self._tracks[num] = t
                            updates.append((num, obs))
                        } else {
                            // Bad/empty tracker result
                            t.misses += 1
                            self._tracks[num] = t
                        }
                    }
                    DispatchQueue.main.async {
                        for (num, obs) in updates {
                            let center = self.rectCenter(self.visionToPreviewRect(obs.boundingBox))
                            if center.y < self.bounds.height - self.buttonAreaHeight {
                                self.ensureTag(for: num, at: center)
                            }
                        }
                    }
                }
            } catch { /* ignore; OCR will re-seed */ }
        }

        // 2) Cleanup stale tracks (miss- or time-based)
        cleanupOldTracks(now: now)

        // 3) OCR every N frames
        guard frameIndex % ocrEveryN == 0 else { return }

        let request = VNRecognizeTextRequest { [weak self] req, err in
            guard let self = self, err == nil,
                  let observations = req.results as? [VNRecognizedTextObservation] else { return }

            for o in observations {
                for cand in o.topCandidates(5) {
                    let original = cand.string
                    guard let regex = self.idRegex else { continue }
                    let ns = NSString(string: original)
                    let range = NSRange(location: 0, length: ns.length)
                    let matches = regex.matches(in: original, range: range)

                    for m in matches {
                        guard let r = Range(m.range, in: original) else { continue }
                        let num = String(original[r])

                        // Respect client list strictly if provided
                        if !self.numbersToMatch.isEmpty && !self.numbersToMatch.contains(num) { continue }

                        // Optional: skip 4-digit years when no list provided
                        if self.numbersToMatch.isEmpty, num.count == 4, let v = Int(num), (1900...2099).contains(v) {
                            continue
                        }

                        guard let subObs = try? cand.boundingBox(for: r) else { continue }
                        let rect = subObs.boundingBox

                        self.upsertTrack(number: num, normRect: rect)

                        let center = self.rectCenter(self.visionToPreviewRect(rect))
                        if center.y < self.bounds.height - self.buttonAreaHeight {
                            DispatchQueue.main.async { self.ensureTag(for: num, at: center) }
                        }

                        if !self.collectedNumbers.contains(num) {
                            self.collectedNumbers.insert(num)
                            self.haptic()
                            self.onNumberCollected?(num)
                        }
                    }
                }
            }
        }

        // OCR config
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = minTextHeight
        if !numbersToMatch.isEmpty { request.customWords = Array(numbersToMatch) }
        if useLeftStripROI { request.regionOfInterest = leftStripROI }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { onDebugUpdate?("OCR failed: \(error.localizedDescription)") }
    }
}
