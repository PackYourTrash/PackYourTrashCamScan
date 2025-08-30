import UIKit
import AVFoundation
import Vision
import CoreHaptics

final class LiveCameraUIView: UIView {

    // MARK: Camera
    private let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.video.queue", qos: .userInitiated)

    // Visible container we rotate back to user-friendly orientation
    private let canvasLayer = CALayer()                 // <- NEW: parent for preview + tags
    private var preview: AVCaptureVideoPreviewLayer!

    // How much to rotate the visible canvas to look upright to the user.
    // -.pi/2 = rotate RIGHT 90° (clockwise). If you want the other way, use +.pi/2.
    private let rotationAngle: CGFloat = -.pi / 2

    // MARK: Track model
    private struct Track {
        let number: String
        var observation: VNDetectedObjectObservation
        var request: VNTrackObjectRequest
        weak var tagLayer: CALayer?
        var lastSeen: Date
        var hits: Int
        var locked: Bool
    }

    // Multiple tracks (one per value)
    private let syncQ = DispatchQueue(label: "tracks.sync", attributes: .concurrent)
    private var _tracks: [String: Track] = [:]
    private var tracks: [String: Track] {
        get { syncQ.sync { _tracks } }
        set { syncQ.async(flags: .barrier) { self._tracks = newValue } }
    }

    // MARK: Public API
    var numbersToMatch: Set<String> = []          // empty = any 4-digit
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
    private let lockHits = 2
    private let timeout: TimeInterval = 1.0
    private let smoothing: CGFloat = 0.80
    private let buttonAreaHeight: CGFloat = 220

    // MARK: Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
        prepareHaptics()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
        prepareHaptics()
    }
    deinit { session.stopRunning() }

    // MARK: Camera setup (LANDSCAPE capture for Vision)
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

        // IMPORTANT: keep the capture stream in landscapeRight (works best with your racks)
        if let c = videoOut.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }

        session.commitConfiguration()

        // Canvas (rotated container) → Preview inside
        canvasLayer.frame = bounds
        layer.addSublayer(canvasLayer)

        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = canvasLayer.bounds
        canvasLayer.addSublayer(preview)

        // Rotate the WHOLE canvas (preview + future tags) back to a user-natural view
        canvasLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotationAngle))

        DispatchQueue.global(qos: .userInteractive).async { self.session.startRunning() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvasLayer.frame = bounds
        preview?.frame = canvasLayer.bounds
        // Keep rotation applied after layout changes
        canvasLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotationAngle))
    }

    // MARK: Orientation mapping for Vision
    private func visionOrientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
        // Our capture connection is landscapeRight → Vision orientation .up
        switch connection.videoOrientation {
        case .landscapeRight: return .up
        case .landscapeLeft:  return .down
        case .portrait:       return .right
        case .portraitUpsideDown: return .left
        @unknown default:     return .up
        }
    }

    // MARK: Geometry helpers
    /// Vision (BL, normalized) → preview layer rect (TL, pixel space), computed BEFORE we rotate the canvas.
    private func visionToPreviewRect(_ v: CGRect) -> CGRect {
        var r = v
        r.origin.y = 1 - r.origin.y - r.height // BL → TL
        return preview.layerRectConverted(fromMetadataOutputRect: r)
    }
    private func rectCenter(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: Tag drawing (value only)
    private func ensureTag(for number: String, at center: CGPoint) {
        let existingLayer = syncQ.sync { _tracks[number]?.tagLayer }

        if let layer = existingLayer {
            let cur = layer.position, s = smoothing
            let smoothed = CGPoint(x: cur.x * s + center.x * (1 - s),
                                   y: cur.y * s + center.y * (1 - s))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.position = smoothed
            if let text = layer.sublayers?.first(where: { $0 is CATextLayer }) as? CATextLayer {
                text.string = number
            }
            CATransaction.commit()
            return
        }

        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.position = center
        container.zPosition = 999

        let label = CATextLayer()
        label.string = number
        label.fontSize = 24
        label.font = UIFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        label.alignmentMode = .center
        label.foregroundColor = UIColor.red.cgColor
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        label.cornerRadius = 10
        label.contentsScale = UIScreen.main.scale
        label.bounds = CGRect(x: 0, y: 0, width: 86, height: 40)
        label.position = .zero
        label.shadowColor = UIColor.black.cgColor
        label.shadowOpacity = 0.7
        label.shadowRadius = 2
        label.shadowOffset = CGSize(width: 0, height: 1)

        container.addSublayer(label)
        // Add tag to the ROTATED canvas so it turns with the preview
        canvasLayer.addSublayer(container)

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
        if let e = engine {
            do {
                let e1 = CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0)
                let e2 = CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0.1)
                let pattern = try CHHapticPattern(events: [e1, e2], parameters: [])
                let player = try e.makePlayer(with: pattern); try? player.start(atTime: 0)
                return
            } catch {}
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Track helpers
    private func updateOrCreateTrack(number: String, normRect: CGRect) {
        let det = VNDetectedObjectObservation(boundingBox: normRect)
        syncQ.async(flags: .barrier) {
            if var t = self._tracks[number] {
                t.observation = det
                t.request.inputObservation = det
                t.lastSeen = Date()
                self._tracks[number] = t
            } else {
                let req = VNTrackObjectRequest(detectedObjectObservation: det)
                req.trackingLevel = .accurate
                self._tracks[number] = Track(number: number,
                                             observation: det,
                                             request: req,
                                             tagLayer: nil,
                                             lastSeen: Date(),
                                             hits: 1,
                                             locked: false)
            }
        }
    }

    private func cleanupOldTracks(now: Date) {
        var toRemove: [String] = []
        syncQ.sync {
            for (num, t) in _tracks where now.timeIntervalSince(t.lastSeen) > timeout {
                toRemove.append(num)
            }
        }
        guard !toRemove.isEmpty else { return }
        DispatchQueue.main.async {
            let layers = self.syncQ.sync { toRemove.compactMap { self._tracks[$0]?.tagLayer } }
            layers.forEach { $0.removeFromSuperlayer() }
        }
        syncQ.async(flags: .barrier) {
            toRemove.forEach { self._tracks.removeValue(forKey: $0) }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension LiveCameraUIView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard isScanning, let pixel = CMSampleBufferGetImageBuffer(sb) else { return }
        frameIndex += 1
        if c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight } // keep capture in landscape

        let orientation = visionOrientation(for: c)
        let now = Date()

        // 1) Run all trackers
        let requests: [VNTrackObjectRequest] = syncQ.sync { Array(self._tracks.values.map { $0.request }) }
        if !requests.isEmpty {
            do {
                try VNSequenceRequestHandler().perform(requests, on: pixel, orientation: orientation)
                syncQ.async(flags: .barrier) {
                    var updated: [(String, VNDetectedObjectObservation)] = []
                    for (num, var t) in self._tracks {
                        if let obs = t.request.results?.first as? VNDetectedObjectObservation {
                            t.observation = obs
                            t.lastSeen = now
                            if t.hits < self.lockHits { t.hits += 1 }
                            if t.hits >= self.lockHits { t.locked = true }
                            self._tracks[num] = t
                            updated.append((num, obs))
                        }
                    }
                    DispatchQueue.main.async {
                        for (num, obs) in updated {
                            let center = self.rectCenter(self.visionToPreviewRect(obs.boundingBox))
                            if center.y < self.bounds.height - self.buttonAreaHeight {
                                self.ensureTag(for: num, at: center)
                            }
                        }
                    }
                }
            } catch { /* OCR will re-acquire */ }
        }

        // 2) Cleanup stale tracks
        cleanupOldTracks(now: now)

        // 3) OCR periodically or while we need more values
        let needMore = numbersToMatch.isEmpty || !numbersToMatch.isSubset(of: Set(tracks.keys))
        if needMore || frameIndex % ocrEveryN == 0 {
            let request = VNRecognizeTextRequest { [weak self] req, err in
                guard let self = self, err == nil,
                      let observations = req.results as? [VNRecognizedTextObservation] else { return }

                var found: [(String, CGRect)] = []

                for o in observations {
                    for cand in o.topCandidates(5) {
                        let original = cand.string
                        // Extract numeric groups from ORIGINAL text to preserve indices
                        let groups = original.split(whereSeparator: { !$0.isNumber }).map(String.init)
                        for g in groups where g.count == 4 {
                            if !self.numbersToMatch.isEmpty && !self.numbersToMatch.contains(g) { continue }
                            if let r = original.range(of: g),
                               let rectObs = try? cand.boundingBox(for: r) {
                                found.append((g, rectObs.boundingBox))
                            }
                        }
                    }
                }

                for (num, normRect) in found {
                    self.updateOrCreateTrack(number: num, normRect: normRect)
                    let center = self.rectCenter(self.visionToPreviewRect(normRect))
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

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.02

            let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
            do { try handler.perform([request]) } catch { onDebugUpdate?("OCR failed: \(error.localizedDescription)") }
        }
    }
}
