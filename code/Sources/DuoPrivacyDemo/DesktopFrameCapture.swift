import AppKit
import CoreMedia
import ScreenCaptureKit

enum DesktopFrameCaptureError: LocalizedError {
    case permissionRequired
    case displayUnavailable
    case appExclusionUnavailable
    case frameUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "需要允许“屏幕录制”权限。请在系统设置 → 隐私与安全性 → 屏幕录制中允许 Duo Privacy Demo，然后退出并重新打开应用。"
        case .displayUnavailable:
            return "没有找到可捕获的主显示器。"
        case .appExclusionUnavailable:
            return "无法安全排除 Duo Privacy Demo 自己的窗口，请退出后重新打开应用。"
        case .frameUnavailable:
            return "没有收到可用的桌面画面。"
        }
    }
}

final class DesktopFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.mj.duoprivacydemo.desktop-frame", qos: .userInteractive)
    private var stream: SCStream?
    private var generation = 0
    private var deliveredFrame = false
    private var frameTimeout: DispatchWorkItem?

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onFailure: ((Error) -> Void)?

    func verifyAccess() async throws {
        if ProcessInfo.processInfo.environment["DUO_TEST_CAPTURE_FAILURE"] == "1" {
            throw DesktopFrameCaptureError.permissionRequired
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw DesktopFrameCaptureError.permissionRequired
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else {
            throw DesktopFrameCaptureError.displayUnavailable
        }
        guard content.applications.contains(where: { $0.processID == getpid() }) else {
            throw DesktopFrameCaptureError.appExclusionUnavailable
        }
    }

    func captureMainDisplay(displayID: CGDirectDisplayID) async throws {
        cancel()
        try await verifyAccess()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DesktopFrameCaptureError.displayUnavailable
        }
        guard let ownApplication = content.applications.first(where: { $0.processID == getpid() }) else {
            throw DesktopFrameCaptureError.appExclusionUnavailable
        }

        generation += 1
        let activeGeneration = generation
        deliveredFrame = false

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [ownApplication],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 1
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()

        let timeout = DispatchWorkItem { [weak self, weak newStream] in
            guard let self, self.generation == activeGeneration, self.stream === newStream, !self.deliveredFrame else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.onFailure?(DesktopFrameCaptureError.frameUnavailable)
                self.cancel()
            }
        }
        frameTimeout = timeout
        sampleQueue.asyncAfter(deadline: .now() + 2.0, execute: timeout)
    }

    func cancel() {
        generation += 1
        deliveredFrame = false
        frameTimeout?.cancel()
        frameTimeout = nil
        let previousStream = stream
        stream = nil
        if let previousStream {
            Task { try? await previousStream.stopCapture() }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int,
        SCFrameStatus(rawValue: rawStatus) == .complete else { return }

        let activeGeneration = generation
        guard !deliveredFrame else { return }
        deliveredFrame = true
        frameTimeout?.cancel()

        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream, self.generation == activeGeneration else { return }
            self.onFrame?(sampleBuffer)
            self.cancel()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream else { return }
            self.onFailure?(error)
            self.cancel()
        }
    }
}
