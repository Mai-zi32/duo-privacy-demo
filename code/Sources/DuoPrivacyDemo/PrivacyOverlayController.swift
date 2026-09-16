import AppKit

final class PrivacyOverlayController {
    private var panel: NSPanel?
    private var overlayView: AmbientOverlayView?
    private let desktopCapture = DesktopFrameCapture()
    private(set) var isVisible = false
    private var isPreparing = false
    private var mediaURL: URL?

    var onManualDismiss: (() -> Void)?

    func setMedia(url: URL?) {
        mediaURL = url
        overlayView?.setMedia(url: url)
    }

    func verifyLiveDesktopAccess() async throws {
        try await desktopCapture.verifyAccess()
    }

    func showLive(
        fallbackOnFailure: Bool = true,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard !isVisible, !isPreparing, let screen = NSScreen.main else { return }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            completion?(.failure(DesktopFrameCaptureError.displayUnavailable))
            return
        }

        let (preparedPanel, preparedView) = makePanel(for: screen)
        panel = preparedPanel
        overlayView = preparedView
        isPreparing = true

        preparedView.onDismiss = { [weak self] in
            self?.onManualDismiss?()
            self?.hide()
        }

        desktopCapture.onFrame = { [weak self, weak preparedPanel, weak preparedView] sampleBuffer in
            guard let self, self.isPreparing, let preparedPanel, let preparedView else { return }
            preparedView.setLiveDesktopFrame(sampleBuffer)
            self.isPreparing = false
            self.isVisible = true
            preparedPanel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard self.isVisible else { return }
                preparedView.animate(to: 1) {}
                completion?(.success(()))
            }
        }

        desktopCapture.onFailure = { [weak self] error in
            self?.finishFailedPreparation(error, fallbackOnFailure: fallbackOnFailure, completion: completion)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.desktopCapture.captureMainDisplay(
                    displayID: CGDirectDisplayID(displayID.uint32Value)
                )
            } catch {
                self.finishFailedPreparation(error, fallbackOnFailure: fallbackOnFailure, completion: completion)
            }
        }
    }

    func showFallback() {
        guard !isVisible, !isPreparing, let screen = NSScreen.main else { return }
        let (preparedPanel, preparedView) = makePanel(for: screen)
        panel = preparedPanel
        overlayView = preparedView
        isVisible = true

        preparedView.setMedia(url: mediaURL)
        preparedView.onDismiss = { [weak self] in
            self?.onManualDismiss?()
            self?.hide()
        }
        preparedPanel.orderFrontRegardless()
        preparedView.animate(to: 1) {}
    }

    func showPreview(at progress: CGFloat) {
        guard !isVisible, !isPreparing, let screen = NSScreen.main else { return }
        let (preparedPanel, preparedView) = makePanel(for: screen)
        panel = preparedPanel
        overlayView = preparedView
        isVisible = true

        preparedView.setMedia(url: mediaURL)
        preparedView.onDismiss = { [weak self] in self?.hide() }
        preparedView.holdPreview(at: progress)
        preparedPanel.orderFrontRegardless()
    }

    func hide(completion: (() -> Void)? = nil) {
        if isPreparing {
            isPreparing = false
            desktopCapture.cancel()
            panel?.orderOut(nil)
            panel = nil
            overlayView = nil
            completion?()
            return
        }

        guard isVisible, let panel, let overlayView else {
            completion?()
            return
        }
        isVisible = false
        overlayView.animate(to: 0) { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.desktopCapture.cancel()
            self?.desktopCapture.onFrame = nil
            self?.desktopCapture.onFailure = nil
            self?.panel = nil
            self?.overlayView = nil
            completion?()
        }
    }

    private func finishFailedPreparation(
        _ error: Error,
        fallbackOnFailure: Bool,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        guard isPreparing else { return }
        isPreparing = false
        desktopCapture.cancel()

        guard fallbackOnFailure, let panel, let overlayView else {
            panel?.orderOut(nil)
            panel = nil
            overlayView = nil
            completion?(.failure(error))
            return
        }

        overlayView.setMedia(url: mediaURL)
        isVisible = true
        panel.orderFrontRegardless()
        overlayView.animate(to: 1) {}
        completion?(.failure(error))
    }

    private func makePanel(for screen: NSScreen) -> (NSPanel, AmbientOverlayView) {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(screen.frame, display: true)
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none

        let view = AmbientOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        return (panel, view)
    }
}
