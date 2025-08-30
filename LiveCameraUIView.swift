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
        var bbox: CGRect           // Vision-normalized rect
        var tagLayer: CALayer?
        var lastSeen: Date
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
    private let ocrEveryN = 3
    private let tagTimeout: TimeInterval = 0.28
    private let smoothing: CGFloat = 0.9
    private let buttonAreaHeight: CGFloat = 220

    // OCR tuning
    private let minTextHeight: Float = 0.02

    // What counts as an ID
    private let minDigits = 4
    private let maxDigits = 6
    private lazy var idRegex: NSRegularExpression? = try? NSRegularExpression(pattern: "\\b\\d{\(minDigits),\(maxDigits)}\\b")

    // Tag style
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

        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.unlockForConfiguration()

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.canAddInput(input) { session.addInput(input) }

        videoOut.setSampleBufferDelegate(self, queue: queue)
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }

        if let c = videoOut.connection(with: .video) {
            if c.isVideoRotationAngleSupported(0.0) { c.videoRotationAngle = 0.0 } // keep buffers upright for Vision
        }

        session.commitConfiguration()

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

    // MARK: Helpers
    private func visionToPreviewRect(_ v: CGRect) -> CGRect {
        var r = v
        r.origin.y = 1 - r.origin.y - r.height // Vision BL → preview TL
        return preview.layerRectConverted(fromMetadataOutputRect: r)
    }
    private func rectCenter(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func pixelAlign(_ p: CGPoint) -> CGPoint { CGPoint(x: round(p.x), y: round(p.y)) }

    // MARK: Tag mgmt
    private func tagSize(for number: String) -> CGSize {
        let charW: CGFloat = 11.5, padding: CGFloat = 24
        return CGSize(width: max(52, CGFloat(number.count) * charW + padding), height: 26)
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

        // Create once
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
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85).cgColor
        label.cornerRadius = 4
        label.contentsScale = UIScreen.main.scale
        label.isWrapped = false
        label.truncationMode = .end
        label.bounds = CGRect(origin: .zero, size: tagSize(for: number))
        label.position = .zero

        container.addSublayer(label)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.addSublayer(container)
        CATransaction.commit()

        // 🔒 Synchronous write avoids the race that caused duplicates
        syncQ.sync(flags: .barrier) {
            if var t = self._tracks[number] { t.tagLayer = container; self._tracks[number] = t }
        }
    }

    private func removeTag(for number: String) {
        let layer = syncQ.sync { _tracks[number]?.tagLayer }
        DispatchQueue.main.async { layer?.removeFromSuperlayer() }
        syncQ.async(flags: .barrier) {
            if var t = self._tracks[number] { t.tagLayer = nil; self._tracks[number] = t }
        }
    }

    private func clearAllTags() {
        let layers = syncQ.sync { _tracks.values.compactMap { $0.tagLayer } }
        DispatchQueue.main.async { layers.forEach { $0.removeFromSuperlayer() } }
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

    // MARK: Cleanup
    private func cleanupOldTracks() {
        let now = Date()
        var stale: [String] = []
        syncQ.sync {
            for (num, t) in _tracks where now.timeIntervalSince(t.lastSeen) > tagTimeout {
                stale.append(num)
            }
        }
        for num in stale { removeTag(for: num) }
        syncQ.async(flags: .barrier) { stale.forEach { self._tracks.removeValue(forKey: $0) } }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension LiveCameraUIView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard isScanning, let pixel = CMSampleBufferGetImageBuffer(sb) else { return }
        frameIndex += 1

        cleanupOldTracks()
        guard frameIndex % ocrEveryN == 0 else { return }

        let request = VNRecognizeTextRequest { [weak self] req, err in
            guard let self = self, err == nil,
                  let observations = req.results as? [VNRecognizedTextObservation] else { return }

            let now = Date()

            // Aggregate: pick ONE best rect per number this frame
            var bestForNumber: [String: CGRect] = [:]
            var bestScore:    [String: CGFloat] = [:]

            for obs in observations {
                guard let text = obs.topCandidates(1).first?.string else { continue }
                guard let regex = self.idRegex else { continue }

                let ns = NSString(string: text)
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    guard let r = Range(m.range, in: text) else { continue }
                    let number = String(text[r])

                    if !self.numbersToMatch.isEmpty && !self.numbersToMatch.contains(number) { continue }
                    if self.numbersToMatch.isEmpty, number.count == 4, let v = Int(number), (1900...2099).contains(v) { continue }

                    guard let bb = try? obs.topCandidates(1).first!.boundingBox(for: r) else { continue }
                    let rect = bb.boundingBox

                    // Score = bigger box + preference for proximity to previous center (if any)
                    let area = rect.width * rect.height
                    let prevCenter = self.syncQ.sync { self._tracks[number].map { self.rectCenter(self.visionToPreviewRect($0.bbox)) } }
                    var score = CGFloat(area)
                    if let pc = prevCenter {
                        let nc = self.rectCenter(self.visionToPreviewRect(rect))
                        let d = hypot(pc.x - nc.x, pc.y - nc.y) + 1
                        score += 0.25 / d // favor close to previous
                    }

                    if score > (bestScore[number] ?? -1) {
                        bestScore[number] = score
                        bestForNumber[number] = rect
                    }
                }
            }

            // Update tracks once per number; draw exactly one tag
            self.syncQ.async(flags: .barrier) {
                for (num, rect) in bestForNumber {
                    if var t = self._tracks[num] {
                        t.bbox = rect; t.lastSeen = now; self._tracks[num] = t
                    } else {
                        self._tracks[num] = Track(number: num, bbox: rect, tagLayer: nil, lastSeen: now)
                    }
                }
            }

            DispatchQueue.main.async {
                for (num, rect) in bestForNumber {
                    let center = self.rectCenter(self.visionToPreviewRect(rect))
                    if center.y < self.bounds.height - self.buttonAreaHeight {
                        self.ensureTag(for: num, at: center)
                    }
                    if !self.collectedNumbers.contains(num) {
                        self.collectedNumbers.insert(num)
                        self.haptic()
                        self.onNumberCollected?(num)
                    }
                }
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = minTextHeight
        if !numbersToMatch.isEmpty { request.customWords = Array(numbersToMatch) }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up, options: [:])
        try? handler.perform([request])
    }
}
