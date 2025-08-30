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
    private let timeout: TimeInterval = 0.3          // Reduced from 0.4 for faster cleanup
    private let smoothing: CGFloat = 0.80
    private let buttonAreaHeight: CGFloat = 220

    // OCR tuning
    private let minTextHeight: Float = 0.02
    private let useLeftStripROI: Bool = false
    private let leftStripROI = CGRect(x: 0.0, y: 0.0, width: 0.25, height: 1.0)

    // What counts as an ID
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

        // Capture stays landscape (angle 0°) for Vision
        if let c = videoOut.connection(with: .video) {
            if c.isVideoRotationAngleSupported(0.0) { c.videoRotationAngle = 0.0 }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            if c.isVideoMirroringSupported { c.isVideoMirrored = false }
        }

        session.commitConfiguration()

        // Portrait preview for the user (angle 90°)
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

    // MARK: Orientation mapping for Vision
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

    // MARK: Geometry helpers
    private func visionToPreviewRect(_ v: CGRect) -> CGRect {
        var r = v
        r.origin.y = 1 - r.origin.y - r.height // Vision BL → preview TL
        return preview.layerRectConverted(fromMetadataOutputRect: r)
    }
    private func rectCenter(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func pixelAlign(_ p: CGPoint) -> CGPoint { CGPoint(x: round(p.x), y: round(p.y)) }

    // MARK: Tag sizing + drawing
    private func tagSize(for number: String) -> CGSize {
        // Increased width for more elongated look
        let charW: CGFloat = 11.5  // Increased from 10.5
        let padding: CGFloat = 24   // Increased from 16 for more padding
        let w = max(52, CGFloat(number.count) * charW + padding)  // Increased min width from 44 to 52
        return CGSize(width: w, height: 26)  // Slightly increased height from 24 to 26
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

        // New small red pill with sharper corners and more transparency
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
        
        // More transparent background (0.85 instead of 0.96)
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85).cgColor
        
        // Sharper corners (4 instead of 8)
        label.cornerRadius = 4
        
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

    private func removeTag(for number: String) {
        // Remove the visual tag for a specific number
        let layer = syncQ.sync { _tracks[number]?.tagLayer }
        DispatchQueue.main.async {
            layer?.removeFromSuperlayer()
        }
        syncQ.async(flags: .barrier) {
            if var t = self._tracks[number] {
                t.tagLayer = nil
                self._tracks[number] = t
            }
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
                self._tracks[number] = t
            } else {
                let req = VNTrackObjectRequest(detectedObjectObservation: det)
                req.trackingLevel = .accurate
                let track = Track(number: number, observation: det, request: req,
                                  tagLayer: nil, lastSeen: Date(), hits: 1, locked: false)
                self._tracks[number] = track
            }
        }
    }

    private func cleanupOldTracks(now: Date) {
        var toRemove: [String] = []
        var layersToRemove: [CALayer] = []
        
        syncQ.sync {
            for (num, t) in _tracks where now.timeIntervalSince(t.lastSeen) > timeout {
                toRemove.append(num)
                if let layer = t.tagLayer {
                    layersToRemove.append(layer)
                }
            }
        }
        
        guard !toRemove.isEmpty else { return }
        
        // Remove visual tags from UI
        DispatchQueue.main.async {
            layersToRemove.forEach { $0.removeFromSuperlayer() }
        }
        
        // Remove tracks from internal storage
        syncQ.async(flags: .barrier) {
            for num in toRemove {
                self._tracks.removeValue(forKey: num)
            }
        }
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

        // 1) Run trackers every frame
        let requests: [VNTrackObjectRequest] = syncQ.sync { Array(self._tracks.values.map { $0.request }) }
        if !requests.isEmpty {
            do {
                try VNSequenceRequestHandler().perform(requests, on: pixel, orientation: orientation)
                
                // Track which numbers were successfully tracked
                var trackedNumbers = Set<String>()
                
                syncQ.sync {
                    for (num, t) in self._tracks {
                        if let obs = t.request.results?.first as? VNDetectedObjectObservation,
                           obs.confidence > 0.1 { // Only consider confident observations
                            trackedNumbers.insert(num)
                        }
                    }
                }
                
                // Update tracks and remove failed ones
                syncQ.async(flags: .barrier) {
                    var updates: [(String, VNDetectedObjectObservation)] = []
                    var toRemove: [String] = []
                    
                    for (num, var t) in self._tracks {
                        if trackedNumbers.contains(num),
                           let obs = t.request.results?.first as? VNDetectedObjectObservation,
                           obs.confidence > 0.1 {
                            // Successfully tracked
                            t.observation = obs
                            t.lastSeen = now
                            if t.hits < self.lockHits { t.hits += 1 }
                            if t.hits >= self.lockHits { t.locked = true }
                            self._tracks[num] = t
                            updates.append((num, obs))
                        } else {
                            // Tracking failed - mark for removal if old enough
                            if now.timeIntervalSince(t.lastSeen) > 0.1 { // Quick removal for failed tracks
                                toRemove.append(num)
                            }
                        }
                    }
                    
                    // Remove failed tracks immediately
                    if !toRemove.isEmpty {
                        DispatchQueue.main.async {
                            for num in toRemove {
                                if let layer = self.syncQ.sync(execute: { self._tracks[num]?.tagLayer }) {
                                    layer.removeFromSuperlayer()
                                }
                            }
                        }
                        for num in toRemove {
                            self._tracks.removeValue(forKey: num)
                        }
                    }
                    
                    // Update positions for successful tracks
                    DispatchQueue.main.async {
                        for (num, obs) in updates {
                            let center = self.rectCenter(self.visionToPreviewRect(obs.boundingBox))
                            if center.y < self.bounds.height - self.buttonAreaHeight {
                                self.ensureTag(for: num, at: center)
                            } else {
                                // Remove tag if it's in the button area
                                self.removeTag(for: num)
                            }
                        }
                    }
                }
            } catch {
                // Tracking failed - will be cleaned up by timeout
            }
        }

        // 2) Cleanup stale tracks (as backup for any that slip through)
        cleanupOldTracks(now: now)

        // 3) OCR every N frames (unconditional)
        guard frameIndex % ocrEveryN == 0 else { return }

        let request = VNRecognizeTextRequest { [weak self] req, err in
            guard let self = self, err == nil,
                  let observations = req.results as? [VNRecognizedTextObservation] else { return }

            // Track which numbers are currently visible
            var currentlyVisible = Set<String>()

            for o in observations {
                for cand in o.topCandidates(5) {
                    let original = cand.string

                    // Find every 4–6 digit group with ranges for Vision
                    guard let regex = self.idRegex else { continue }
                    let ns = NSString(string: original)
                    let range = NSRange(location: 0, length: ns.length)
                    let matches = regex.matches(in: original, range: range)

                    for m in matches {
                        guard let r = Range(m.range, in: original) else { continue }
                        let num = String(original[r])

                        // If caller gave a list, enforce it strictly
                        if !self.numbersToMatch.isEmpty && !self.numbersToMatch.contains(num) { continue }

                        // Optional: skip years only when no list is provided and exactly 4 digits
                        if self.numbersToMatch.isEmpty, num.count == 4, let v = Int(num), (1900...2099).contains(v) {
                            continue
                        }

                        currentlyVisible.insert(num)

                        // Ask Vision for the bbox of just this substring
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
            
            // Remove tags for numbers no longer visible
            self.syncQ.async(flags: .barrier) {
                var toRemove: [(String, CALayer?)] = []
                for (num, t) in self._tracks {
                    if !currentlyVisible.contains(num) && now.timeIntervalSince(t.lastSeen) > 0.15 {
                        toRemove.append((num, t.tagLayer))
                    }
                }
                
                if !toRemove.isEmpty {
                    DispatchQueue.main.async {
                        for (_, layer) in toRemove {
                            layer?.removeFromSuperlayer()
                        }
                    }
                    for (num, _) in toRemove {
                        self._tracks.removeValue(forKey: num)
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
