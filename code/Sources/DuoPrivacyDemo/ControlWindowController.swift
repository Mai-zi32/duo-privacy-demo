import AppKit

final class ControlWindowController: NSWindowController, NSWindowDelegate {
    var onToggleMonitoring: (() -> Void)?
    var onPreviewLiveDesktop: (() -> Void)?
    var onPreviewFallback: (() -> Void)?
    var onModeChange: ((PrivacyMode) -> Void)?
    var onCameraPermissionAction: (() -> Void)?
    var onScreenPermissionAction: (() -> Void)?
    var onRefreshPermissions: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "未启用")
    private let monitoringButton = NSButton()
    private let mainContainer = NSView()
    private let permissionContainer = NSView()
    private let cameraStatusLabel = NSTextField(labelWithString: "尚未允许")
    private let screenStatusLabel = NSTextField(labelWithString: "尚未允许")
    private let cameraPermissionButton = NSButton()
    private let screenPermissionButton = NSButton()
    private lazy var modeControl = NSSegmentedControl(
        labels: PrivacyMode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: self,
        action: #selector(modeChanged)
    )

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 530),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Duo Privacy Demo"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(status: String, monitoring: Bool, mode: PrivacyMode) {
        statusLabel.stringValue = "状态：\(status)"
        monitoringButton.title = monitoring ? "暂停注视检测" : "开始注视检测"
        modeControl.selectedSegment = PrivacyMode.allCases.firstIndex(of: mode) ?? 0
        modeControl.isEnabled = !monitoring
    }

    func updatePermissions(_ state: RequiredPermissionState) {
        apply(
            state.camera,
            to: cameraStatusLabel,
            button: cameraPermissionButton,
            requestTitle: "允许摄像头"
        )
        apply(
            state.screenRecording,
            to: screenStatusLabel,
            button: screenPermissionButton,
            requestTitle: "允许屏幕录制"
        )

        permissionContainer.isHidden = state.isReady
        mainContainer.isHidden = !state.isReady
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func toggleMonitoring() {
        onToggleMonitoring?()
    }

    @objc private func previewLiveDesktop() {
        onPreviewLiveDesktop?()
    }

    @objc private func previewFallback() {
        onPreviewFallback?()
    }

    @objc private func cameraPermissionAction() {
        onCameraPermissionAction?()
    }

    @objc private func screenPermissionAction() {
        onScreenPermissionAction?()
    }

    @objc private func refreshPermissions() {
        onRefreshPermissions?()
    }

    @objc private func modeChanged() {
        let modes = PrivacyMode.allCases
        guard modes.indices.contains(modeControl.selectedSegment) else { return }
        onModeChange?(modes[modeControl.selectedSegment])
    }

    private func makeContentView() -> NSView {
        let visual = NSVisualEffectView()
        visual.material = .contentBackground
        visual.blendingMode = .behindWindow
        visual.state = .active

        for container in [mainContainer, permissionContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            visual.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
                container.topAnchor.constraint(equalTo: visual.topAnchor),
                container.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
            ])
        }

        buildMainControls(in: mainContainer)
        buildPermissionGuide(in: permissionContainer)
        return visual
    }

    private func buildMainControls(in container: NSView) {
        let title = NSTextField(labelWithString: "Duo Privacy")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: "当你转头或离开时，当前屏幕会像一整块玻璃从左向右变成毛玻璃，遮住内容细节。")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor

        let modeLabel = NSTextField(labelWithString: "隐私模式")
        modeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modeLabel.textColor = .secondaryLabelColor

        modeControl.selectedSegment = 0

        monitoringButton.title = "开始注视检测"
        monitoringButton.bezelStyle = .rounded
        monitoringButton.controlSize = .large
        monitoringButton.target = self
        monitoringButton.action = #selector(toggleMonitoring)

        let livePreviewButton = makeButton(title: "预览真实屏幕效果", action: #selector(previewLiveDesktop))
        let fallbackPreviewButton = makeButton(title: "预览备用背景（无需权限）", action: #selector(previewFallback))

        let privacy = NSTextField(wrappingLabelWithString: "摄像头和屏幕画面只在本机内存中处理，不保存、不上传。\n遮罩出现后点击即可返回。")
        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = .tertiaryLabelColor
        privacy.alignment = .center
        privacy.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            title,
            subtitle,
            modeLabel,
            modeControl,
            statusLabel,
            monitoringButton,
            livePreviewButton,
            fallbackPreviewButton,
            privacy
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(6, after: modeLabel)
        stack.setCustomSpacing(18, after: modeControl)
        stack.setCustomSpacing(14, after: statusLabel)
        stack.setCustomSpacing(22, after: fallbackPreviewButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        for button in [monitoringButton, livePreviewButton, fallbackPreviewButton] {
            button.widthAnchor.constraint(equalToConstant: 300).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        subtitle.widthAnchor.constraint(equalToConstant: 360).isActive = true
        privacy.widthAnchor.constraint(equalToConstant: 360).isActive = true
        modeControl.widthAnchor.constraint(equalToConstant: 300).isActive = true

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    private func buildPermissionGuide(in container: NSView) {
        let symbol = NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "隐私权限") ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 34, weight: .medium)
        symbol.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "开始使用 Duo Privacy")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: "需要两项 macOS 权限，才能识别你的注意力并把当前屏幕变成毛玻璃。")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.widthAnchor.constraint(equalToConstant: 380).isActive = true

        cameraPermissionButton.target = self
        cameraPermissionButton.action = #selector(cameraPermissionAction)
        screenPermissionButton.target = self
        screenPermissionButton.action = #selector(screenPermissionAction)

        let cameraRow = makePermissionRow(
            symbol: "camera.fill",
            title: "摄像头",
            detail: "只在本机判断人脸和视线，不录制、不保存。",
            statusLabel: cameraStatusLabel,
            button: cameraPermissionButton
        )
        let screenRow = makePermissionRow(
            symbol: "rectangle.on.rectangle",
            title: "录屏与系统录音",
            detail: "只读取当前主屏幕作为毛玻璃背景，不采集声音。",
            statusLabel: screenStatusLabel,
            button: screenPermissionButton
        )

        let refreshButton = NSButton(title: "重新检查权限", target: self, action: #selector(refreshPermissions))
        refreshButton.bezelStyle = .inline
        refreshButton.font = .systemFont(ofSize: 12, weight: .medium)

        let previewButton = NSButton(title: "先预览效果（无需权限）", target: self, action: #selector(previewFallback))
        previewButton.bezelStyle = .inline
        previewButton.font = .systemFont(ofSize: 12, weight: .regular)

        let footnote = NSTextField(wrappingLabelWithString: "所有分析都在这台 Mac 上完成。录屏权限更改后，macOS 可能要求退出并重新打开应用。")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        footnote.alignment = .center
        footnote.maximumNumberOfLines = 2
        footnote.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let actions = NSStackView(views: [refreshButton, previewButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 18

        let stack = NSStackView(views: [symbol, title, subtitle, cameraRow, screenRow, actions, footnote])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(8, after: symbol)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(18, after: screenRow)
        stack.setCustomSpacing(18, after: actions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    private func makePermissionRow(
        symbol: String,
        title: String,
        detail: String,
        statusLabel: NSTextField,
        button: NSButton
    ) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.alignment = .right

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let action = NSStackView(views: [statusLabel, button])
        action.orientation = .vertical
        action.alignment = .trailing
        action.spacing = 5

        let row = NSStackView(views: [icon, copy, action])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 400),
            card.heightAnchor.constraint(equalToConstant: 82),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        return card
    }

    private func apply(
        _ state: PermissionGrantState,
        to statusLabel: NSTextField,
        button: NSButton,
        requestTitle: String
    ) {
        button.isHidden = false
        button.isEnabled = true

        switch state {
        case .authorized:
            statusLabel.stringValue = "✓ 已允许"
            statusLabel.textColor = .systemGreen
            button.isHidden = true
        case .notDetermined:
            statusLabel.stringValue = "尚未允许"
            statusLabel.textColor = .secondaryLabelColor
            button.title = requestTitle
        case .denied:
            statusLabel.stringValue = "未允许"
            statusLabel.textColor = .systemOrange
            button.title = "打开系统设置"
        case .restricted:
            statusLabel.stringValue = "被系统限制"
            statusLabel.textColor = .systemRed
            button.title = "打开系统设置"
        case .restartRequired:
            statusLabel.stringValue = "需要重新打开"
            statusLabel.textColor = .systemOrange
            button.title = "退出应用"
        }
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
}
