import AppKit
import AVFoundation
import CoreMedia
import QuartzCore

final class AmbientOverlayView: NSView {
    var onDismiss: (() -> Void)?

    private let surfaceLayer = CALayer()
    private let baseGradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private let desktopLayer = AVSampleBufferDisplayLayer()
    private let imageLayer = CALayer()
    private let clockLayer = CATextLayer()
    private let dateLayer = CATextLayer()
    private let hintLayer = CATextLayer()

    private let contentFrostView = NSVisualEffectView()
    private let frostMaskLayer = CAGradientLayer()

    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var clockTimer: Timer?
    private var progress: CGFloat = 0

    private let overscan: CGFloat = 6
    private let transitionWidth: CGFloat = 0.14
    private let clearFrostAlpha: CGFloat = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
        updateClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        clockTimer?.invalidate()
        player?.pause()
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()

        let expandedBounds = bounds.insetBy(dx: -overscan, dy: -overscan)
        surfaceLayer.frame = expandedBounds
        baseGradientLayer.frame = surfaceLayer.bounds
        glowLayer.frame = surfaceLayer.bounds
        desktopLayer.frame = surfaceLayer.bounds
        imageLayer.frame = surfaceLayer.bounds
        playerLayer?.frame = surfaceLayer.bounds

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for textLayer in [clockLayer, dateLayer, hintLayer] {
            textLayer.contentsScale = scale
        }

        clockLayer.frame = CGRect(
            x: surfaceLayer.bounds.midX - 260,
            y: surfaceLayer.bounds.midY - 12,
            width: 520,
            height: 116
        )
        dateLayer.frame = CGRect(
            x: surfaceLayer.bounds.midX - 220,
            y: clockLayer.frame.minY - 38,
            width: 440,
            height: 28
        )
        hintLayer.frame = CGRect(
            x: surfaceLayer.bounds.midX - 220,
            y: 42,
            width: 440,
            height: 24
        )

        contentFrostView.frame = expandedBounds
        frostMaskLayer.frame = contentFrostView.bounds.insetBy(dx: -overscan, dy: 0)
        applyStaticFrostState(progress)
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    func setMedia(url: URL?) {
        desktopLayer.flushAndRemoveImage()
        desktopLayer.isHidden = true
        player?.pause()
        player = nil
        playerLooper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        imageLayer.contents = nil
        imageLayer.isHidden = true
        baseGradientLayer.isHidden = false
        glowLayer.isHidden = false
        clockLayer.isHidden = false
        dateLayer.isHidden = false
        hintLayer.isHidden = false

        guard let url else { return }

        if let image = NSImage(contentsOf: url) {
            imageLayer.contents = image
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.isHidden = false
            baseGradientLayer.isHidden = true
            glowLayer.isHidden = true
            return
        }

        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none
        let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        let videoLayer = AVPlayerLayer(player: queuePlayer)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.frame = surfaceLayer.bounds
        videoLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull()
        ]
        surfaceLayer.insertSublayer(videoLayer, above: glowLayer)

        player = queuePlayer
        playerLooper = looper
        playerLayer = videoLayer
        baseGradientLayer.isHidden = true
        glowLayer.isHidden = true
        queuePlayer.play()
    }

    func setLiveDesktopFrame(_ sampleBuffer: CMSampleBuffer) {
        player?.pause()
        player = nil
        playerLooper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        imageLayer.contents = nil
        imageLayer.isHidden = true
        baseGradientLayer.isHidden = true
        glowLayer.isHidden = true
        clockLayer.isHidden = true
        dateLayer.isHidden = true
        hintLayer.isHidden = true

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        desktopLayer.flushAndRemoveImage()
        desktopLayer.isHidden = false
        desktopLayer.enqueue(sampleBuffer)
    }

    func animate(to target: CGFloat, completion: @escaping () -> Void) {
        let destination = min(max(target, 0), 1)
        let opening = destination > progress
        let duration: CFTimeInterval = opening ? 0.86 : 0.82
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.20, 1.0)
        let fromProgress = progress
        progress = destination

        layer?.removeAllAnimations()
        surfaceLayer.removeAllAnimations()
        frostMaskLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = opening ? 1 : 0
        surfaceLayer.transform = CATransform3DIdentity
        frostMaskLayer.locations = frostLocations(for: destination)
        frostMaskLayer.colors = boundaryFrostColors
        CATransaction.commit()

        let rootOpacity = CAKeyframeAnimation(keyPath: "opacity")
        rootOpacity.values = opening ? [0, 1, 1] : [1, 1, 0]
        rootOpacity.keyTimes = opening ? [0, 0.10, 1] : [0, 0.58, 1]
        rootOpacity.duration = duration
        rootOpacity.timingFunctions = [timing, timing]
        layer?.add(rootOpacity, forKey: "duo.rootOpacity")

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = opening ? 1.012 : 1.0
        scaleAnimation.toValue = opening ? 1.0 : 1.008
        scaleAnimation.duration = duration
        scaleAnimation.timingFunction = timing
        surfaceLayer.add(scaleAnimation, forKey: "duo.surfaceScale")

        let locationsAnimation = CABasicAnimation(keyPath: "locations")
        locationsAnimation.fromValue = frostLocations(for: fromProgress)
        locationsAnimation.toValue = frostLocations(for: destination)
        locationsAnimation.duration = duration
        locationsAnimation.timingFunction = timing
        frostMaskLayer.add(locationsAnimation, forKey: "duo.frostTravel")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            completion()
        }
    }

    func holdPreview(at value: CGFloat) {
        progress = min(max(value, 0), 1)
        layer?.removeAllAnimations()
        surfaceLayer.removeAllAnimations()
        frostMaskLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 1
        surfaceLayer.transform = CATransform3DIdentity
        applyStaticFrostState(progress)
        CATransaction.commit()
    }

    private func configureLayers() {
        wantsLayer = true
        guard let rootLayer = layer else { return }
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.opacity = 0
        rootLayer.masksToBounds = true

        surfaceLayer.backgroundColor = NSColor.black.cgColor
        surfaceLayer.allowsEdgeAntialiasing = false
        surfaceLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        surfaceLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull()
        ]
        rootLayer.addSublayer(surfaceLayer)

        baseGradientLayer.type = .axial
        baseGradientLayer.colors = [
            NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.075, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.10, green: 0.065, blue: 0.16, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.015, green: 0.018, blue: 0.035, alpha: 1).cgColor
        ]
        baseGradientLayer.locations = [0, 0.52, 1]
        baseGradientLayer.startPoint = CGPoint(x: 0.05, y: 0.95)
        baseGradientLayer.endPoint = CGPoint(x: 0.95, y: 0.05)
        surfaceLayer.addSublayer(baseGradientLayer)

        glowLayer.type = .radial
        glowLayer.colors = [
            NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.72, alpha: 0.54).cgColor,
            NSColor(calibratedRed: 0.12, green: 0.08, blue: 0.25, alpha: 0.18).cgColor,
            NSColor.clear.cgColor
        ]
        glowLayer.locations = [0, 0.42, 1]
        glowLayer.startPoint = CGPoint(x: 0.26, y: 0.70)
        glowLayer.endPoint = CGPoint(x: 0.92, y: 0.08)
        surfaceLayer.addSublayer(glowLayer)

        desktopLayer.videoGravity = .resizeAspectFill
        desktopLayer.backgroundColor = NSColor.black.cgColor
        desktopLayer.isHidden = true
        desktopLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull()
        ]
        surfaceLayer.addSublayer(desktopLayer)

        imageLayer.isHidden = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        surfaceLayer.addSublayer(imageLayer)

        configureTextLayer(clockLayer, fontSize: 82, weight: .thin)
        configureTextLayer(dateLayer, fontSize: 18, weight: .medium)
        configureTextLayer(hintLayer, fontSize: 13, weight: .regular)
        hintLayer.string = "点击任意位置返回"
        hintLayer.foregroundColor = NSColor.white.withAlphaComponent(0.58).cgColor
        surfaceLayer.addSublayer(clockLayer)
        surfaceLayer.addSublayer(dateLayer)
        surfaceLayer.addSublayer(hintLayer)

        contentFrostView.material = .fullScreenUI
        contentFrostView.blendingMode = .withinWindow
        contentFrostView.state = .active
        contentFrostView.wantsLayer = true
        contentFrostView.layer?.masksToBounds = false
        contentFrostView.layer?.mask = frostMaskLayer
        addSubview(contentFrostView)

        frostMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        frostMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        frostMaskLayer.colors = boundaryFrostColors
        frostMaskLayer.locations = frostLocations(for: 0)
        frostMaskLayer.actions = [
            "colors": NSNull(),
            "locations": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
    }

    private func configureTextLayer(_ textLayer: CATextLayer, fontSize: CGFloat, weight: NSFont.Weight) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        textLayer.font = font
        textLayer.fontSize = fontSize
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
    }

    private func updateClock() {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "M月d日 EEEE"

        clockLayer.string = timeFormatter.string(from: Date())
        dateLayer.string = dateFormatter.string(from: Date())
    }

    private func applyStaticFrostState(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        frostMaskLayer.locations = frostLocations(for: clamped)
        frostMaskLayer.colors = boundaryFrostColors
    }

    private func frostLocations(for value: CGFloat) -> [NSNumber] {
        let clamped = min(max(value, 0), 1)
        // Move the full-width optical boundary completely offscreen at both
        // ends. Clamping the leading edge at 1.0 used to compress the final
        // segment and forced a separate full-screen density fade.
        let boundaryCenter = -transitionWidth + clamped * (1 + 2 * transitionWidth)
        let clearEnd = min(1, max(0, boundaryCenter - transitionWidth))
        let frostStart = min(1, max(0, boundaryCenter + transitionWidth))
        return [0, NSNumber(value: Double(clearEnd)), NSNumber(value: Double(frostStart)), 1]
    }

    private var boundaryFrostColors: [CGColor] {
        let clear = NSColor.black.withAlphaComponent(clearFrostAlpha).cgColor
        let full = NSColor.black.cgColor
        return [full, full, clear, clear]
    }

}
