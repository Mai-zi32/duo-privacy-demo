import AppKit
import AVFoundation
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let attentionMonitor = AttentionMonitor()
    private let overlayController = PrivacyOverlayController()
    private let attentionGate = AttentionGate()
    private let multiPersonGate = MultiPersonAttentionGate()
    private let controlWindowController = ControlWindowController()
    private var statusItem: NSStatusItem?
    private var monitoringEnabled = false
    private var selectedMode: PrivacyMode = .singlePerson
    private var statusText = "未启用"
    private var screenPermissionRequestAttempted = false
    private var screenRestartRequired = false
    private let isPermissionPreview = ProcessInfo.processInfo.arguments.contains("--preview-permissions")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        configureControlWindow()
        refreshPermissionState()
        if let mediaArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-media=") }) {
            let path = String(mediaArgument.dropFirst("--preview-media=".count))
            overlayController.setMedia(url: URL(fileURLWithPath: path))
        }
        attentionMonitor.onUpdate = { [weak self] update in
            self?.handle(update)
        }
        overlayController.onManualDismiss = { [weak self] in
            guard let self else { return }
            switch self.selectedMode {
            case .singlePerson:
                self.attentionGate.reset()
            case .multiPerson:
                self.multiPersonGate.dismissCoverPreservingArmed()
            }
        }

        if let progressArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-progress=") }),
           let progress = Double(progressArgument.split(separator: "=").last ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.overlayController.showPreview(at: CGFloat(progress))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--preview-live-failure") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.previewLiveDesktopEffect()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--preview-hold") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.overlayController.showFallback()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--preview-once") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.runOneShotPreview()
            }
        } else {
            controlWindowController.present()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshPermissionState()
        controlWindowController.present()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        attentionMonitor.stop()
    }

    @objc private func toggleMonitoring() {
        guard currentPermissionState.isReady else {
            refreshPermissionState()
            controlWindowController.present()
            return
        }

        if monitoringEnabled {
            monitoringEnabled = false
            attentionMonitor.stop()
            overlayController.hide()
            attentionGate.reset()
            multiPersonGate.reset()
            statusText = "已暂停"
            rebuildMenu()
            return
        }

        statusText = "正在请求摄像头…"
        rebuildMenu()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.statusText = "正在请求屏幕录制…"
                self.rebuildMenu()
                try await self.overlayController.verifyLiveDesktopAccess()
                self.startCameraMonitoring()
            } catch {
                self.monitoringEnabled = false
                self.statusText = "需要屏幕录制权限"
                self.rebuildMenu()
                self.showError(error.localizedDescription)
            }
        }
    }

    private func startCameraMonitoring() {
        statusText = "正在请求摄像头…"
        rebuildMenu()
        attentionMonitor.start(mode: selectedMode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.monitoringEnabled = true
                self.statusText = self.selectedMode == .multiPerson ? "正在设置主控人" : "正在观察"
                self.rebuildMenu()
            case .failure(let error):
                self.monitoringEnabled = false
                self.statusText = "摄像头不可用"
                self.rebuildMenu()
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func previewFallbackEffect() {
        overlayController.showFallback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            self?.overlayController.hide()
        }
    }

    @objc private func previewLiveDesktopEffect() {
        guard currentPermissionState.screenRecording.isAuthorized else {
            refreshPermissionState()
            controlWindowController.present()
            return
        }

        statusText = "正在读取主屏幕…"
        rebuildMenu()
        overlayController.showLive(fallbackOnFailure: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.statusText = "正在预览真实屏幕"
                self.rebuildMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                    self?.overlayController.hide()
                }
            case .failure(let error):
                self.statusText = "需要屏幕录制权限"
                self.rebuildMenu()
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showControlWindow() {
        refreshPermissionState()
        controlWindowController.present()
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◉"
        item.button?.toolTip = "Duo Privacy Demo"
        statusItem = item
        rebuildMenu()
    }

    private func configureControlWindow() {
        controlWindowController.onToggleMonitoring = { [weak self] in self?.toggleMonitoring() }
        controlWindowController.onPreviewLiveDesktop = { [weak self] in self?.previewLiveDesktopEffect() }
        controlWindowController.onPreviewFallback = { [weak self] in self?.previewFallbackEffect() }
        controlWindowController.onModeChange = { [weak self] mode in self?.changeMode(to: mode) }
        controlWindowController.onCameraPermissionAction = { [weak self] in self?.cameraPermissionAction() }
        controlWindowController.onScreenPermissionAction = { [weak self] in self?.screenPermissionAction() }
        controlWindowController.onRefreshPermissions = { [weak self] in self?.refreshPermissionState() }
        controlWindowController.update(status: statusText, monitoring: monitoringEnabled, mode: selectedMode)
    }

    private func changeMode(to mode: PrivacyMode) {
        guard mode != selectedMode else { return }
        if monitoringEnabled {
            monitoringEnabled = false
            attentionMonitor.stop()
            overlayController.hide()
        }
        attentionGate.reset()
        multiPersonGate.reset()
        selectedMode = mode
        statusText = mode == .multiPerson ? "多人模式未启用" : "单人模式未启用"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let permissionState = currentPermissionState
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开控制面板", action: #selector(showControlWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let status = NSMenuItem(title: "状态：\(statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let monitorTitle = monitoringEnabled ? "暂停注视检测" : "开始注视检测"
        let monitor = NSMenuItem(title: monitorTitle, action: #selector(toggleMonitoring), keyEquivalent: "")
        monitor.target = self
        monitor.isEnabled = permissionState.isReady
        menu.addItem(monitor)

        let livePreview = NSMenuItem(title: "预览真实屏幕效果", action: #selector(previewLiveDesktopEffect), keyEquivalent: "p")
        livePreview.target = self
        livePreview.isEnabled = permissionState.screenRecording.isAuthorized
        menu.addItem(livePreview)

        let fallbackPreview = NSMenuItem(title: "预览备用背景（无需权限）", action: #selector(previewFallbackEffect), keyEquivalent: "")
        fallbackPreview.target = self
        menu.addItem(fallbackPreview)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Duo Privacy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.title = monitoringEnabled ? "●" : "◉"
        controlWindowController.update(status: statusText, monitoring: monitoringEnabled, mode: selectedMode)
        controlWindowController.updatePermissions(permissionState)
    }

    private func handle(_ update: AttentionUpdate) {
        guard monitoringEnabled else { return }
        switch update {
        case .single(let sample):
            handleSinglePerson(sample)
        case .multi(let observation):
            handleMultiplePeople(observation)
        }
        rebuildMenu()
    }

    private func handleSinglePerson(_ sample: AttentionSample) {
        switch sample {
        case .looking:
            statusText = "正在看屏幕"
        case .turnedAway, .absent:
            statusText = sample == .absent ? "未检测到人脸" : "视线已移开"
        case .uncertain:
            statusText = "视线暂时不确定"
        }

        applyOverlayAction(attentionGate.update(
            sample: sample,
            at: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func handleMultiplePeople(_ observation: MultiPersonObservation) {
        let action = multiPersonGate.update(observation, at: ProcessInfo.processInfo.systemUptime)

        switch observation.registration {
        case .needsSingleFace:
            statusText = observation.faceCount > 1
                ? "请让主控人单独面对镜头"
                : "正在寻找主控人"
        case .registering(let progress):
            statusText = "正在设置主控人 \(Int(progress * 100))%"
        case .ready:
            if !multiPersonGate.isArmed {
                statusText = "主控人已识别，等待其他人出现"
            } else {
                switch observation.controllerAttention ?? .absent {
                case .looking:
                    statusText = "多人警戒中 · 主控人正在看"
                case .turnedAway:
                    statusText = "多人警戒中 · 主控人视线移开"
                case .absent:
                    statusText = "多人警戒中 · 主控人已离开"
                case .uncertain:
                    statusText = "多人警戒中 · 主控人视线不确定"
                }
            }
        }

        applyOverlayAction(action)
    }

    private func applyOverlayAction(_ action: AttentionGateAction) {
        switch action {
        case .cover:
            overlayController.showLive(fallbackOnFailure: true) { [weak self] result in
                if case .failure = result {
                    self?.statusText = "屏幕采集不可用，已使用备用背景"
                    self?.rebuildMenu()
                }
            }
        case .reveal:
            overlayController.hide()
        case .none:
            break
        }
    }

    private var currentPermissionState: RequiredPermissionState {
        if isPermissionPreview {
            return RequiredPermissionState(camera: .notDetermined, screenRecording: .notDetermined)
        }

        let camera: PermissionGrantState
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera = .authorized
        case .notDetermined:
            camera = .notDetermined
        case .denied:
            camera = .denied
        case .restricted:
            camera = .restricted
        @unknown default:
            camera = .restricted
        }

        let screenRecording: PermissionGrantState
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .authorized
        } else if screenRestartRequired {
            screenRecording = .restartRequired
        } else if screenPermissionRequestAttempted {
            screenRecording = .denied
        } else {
            screenRecording = .notDetermined
        }

        return RequiredPermissionState(camera: camera, screenRecording: screenRecording)
    }

    private func refreshPermissionState() {
        let state = currentPermissionState
        if !state.isReady && !monitoringEnabled {
            statusText = state.screenRecording == .restartRequired
                ? "录屏权限更改后需要重新打开"
                : "需要完成权限设置"
        } else if state.isReady && [
            "需要完成权限设置",
            "录屏权限更改后需要重新打开"
        ].contains(statusText) {
            statusText = "未启用"
        }
        rebuildMenu()
    }

    private func cameraPermissionAction() {
        guard !isPermissionPreview else { return }

        switch currentPermissionState.camera {
        case .authorized:
            refreshPermissionState()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshPermissionState()
                }
            }
        case .denied, .restricted:
            openSystemSettings(anchor: "Privacy_Camera")
        case .restartRequired:
            break
        }
    }

    private func screenPermissionAction() {
        guard !isPermissionPreview else { return }

        switch currentPermissionState.screenRecording {
        case .authorized:
            refreshPermissionState()
        case .notDetermined:
            screenPermissionRequestAttempted = true
            let granted = CGRequestScreenCaptureAccess()
            screenRestartRequired = granted && !CGPreflightScreenCaptureAccess()
            refreshPermissionState()
        case .denied, .restricted:
            screenRestartRequired = true
            refreshPermissionState()
            openSystemSettings(anchor: "Privacy_ScreenCapture")
        case .restartRequired:
            NSApplication.shared.terminate(nil)
        }
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func runOneShotPreview() {
        overlayController.showFallback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.overlayController.hide {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Duo Privacy 无法启动"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
