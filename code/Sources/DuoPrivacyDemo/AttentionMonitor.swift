import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Vision

enum AttentionMonitorError: LocalizedError {
    case cameraDenied
    case cameraUnavailable
    case cameraConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .cameraDenied:
            return "没有摄像头权限。请在系统设置的隐私与安全性中允许摄像头访问。"
        case .cameraUnavailable:
            return "没有找到可用摄像头。"
        case .cameraConfigurationFailed:
            return "摄像头无法启动。"
        }
    }
}

final class AttentionMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onUpdate: ((AttentionUpdate) -> Void)?

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.mj.duoprivacy.camera", qos: .userInitiated)
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var isConfigured = false
    private var lastProcessedAt: CFTimeInterval = 0

    private var activeMode: PrivacyMode = .singlePerson
    private var tracker = SessionFaceTracker()
    private var controllerProfile: SessionControllerProfile?
    private var registrationTrackID: Int?
    private var registrationPrints: [VNFeaturePrintObservation] = []
    private var registrationGazes: [NormalizedGaze] = []
    private var smoothedControllerGaze: NormalizedGaze?
    private var analyzedFrameCount = 0

    var isRunning: Bool { session.isRunning }

    func start(mode: PrivacyMode, completion: @escaping (Result<Void, Error>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(mode: mode, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    DispatchQueue.main.async { completion(.failure(AttentionMonitorError.cameraDenied)) }
                    return
                }
                self?.configureAndStart(mode: mode, completion: completion)
            }
        default:
            completion(.failure(AttentionMonitorError.cameraDenied))
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.resetRecognitionState()
        }
    }

    private func configureAndStart(
        mode: PrivacyMode,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            do {
                self.activeMode = mode
                self.resetRecognitionState()
                if !self.isConfigured {
                    try self.configureSession()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw AttentionMonitorError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AttentionMonitorError.cameraConfigurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        isConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastProcessedAt >= 0.20 else { return }
        lastProcessedAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .upMirrored,
            options: [:]
        )

        do {
            try handler.perform([faceRequest])
            let faces = faceRequest.results ?? []
            switch activeMode {
            case .singlePerson:
                processSinglePerson(faces)
            case .multiPerson:
                processMultiplePeople(faces, pixelBuffer: pixelBuffer)
            }
        } catch {
            switch activeMode {
            case .singlePerson:
                emit(.single(.absent))
            case .multiPerson:
                emit(.multi(MultiPersonObservation(
                    faceCount: 0,
                    registration: controllerProfile == nil ? .needsSingleFace : .ready,
                    controllerAttention: nil
                )))
            }
        }
    }

    private func processSinglePerson(_ faces: [VNFaceObservation]) {
        guard let face = faces.max(by: { area(of: $0) < area(of: $1) }) else {
            emit(.single(.absent))
            return
        }
        emit(.single(isHeadForward(face) ? .looking : .turnedAway))
    }

    private func processMultiplePeople(
        _ faces: [VNFaceObservation],
        pixelBuffer: CVPixelBuffer
    ) {
        analyzedFrameCount += 1
        let trackIDs = tracker.update(faces.map(\.boundingBox))
        let trackedFaces = zip(faces, trackIDs).map {
            TrackedFaceObservation(face: $0.0, trackID: $0.1)
        }

        guard let profile = controllerProfile else {
            registerController(from: trackedFaces, pixelBuffer: pixelBuffer)
            return
        }

        let controller = findController(
            profile: profile,
            among: trackedFaces,
            pixelBuffer: pixelBuffer
        )
        let attention = controller.map {
            controllerAttention(for: $0.face, baseline: profile.gazeBaseline)
        }
        if controller == nil { smoothedControllerGaze = nil }

        emit(.multi(MultiPersonObservation(
            faceCount: faces.count,
            registration: .ready,
            controllerAttention: attention
        )))
    }

    private func registerController(
        from faces: [TrackedFaceObservation],
        pixelBuffer: CVPixelBuffer
    ) {
        guard faces.count == 1, let candidate = faces.first, isHeadForward(candidate.face) else {
            clearRegistrationSamples()
            emit(.multi(MultiPersonObservation(
                faceCount: faces.count,
                registration: .needsSingleFace,
                controllerAttention: nil
            )))
            return
        }

        if registrationTrackID != candidate.trackID {
            clearRegistrationSamples()
            registrationTrackID = candidate.trackID
        }

        if let print = featurePrint(for: candidate.face, pixelBuffer: pixelBuffer) {
            registrationPrints.append(print)
        }
        if let gaze = normalizedGaze(for: candidate.face) {
            registrationGazes.append(gaze)
        }

        let requiredSamples = 5
        guard registrationPrints.count >= requiredSamples else {
            emit(.multi(MultiPersonObservation(
                faceCount: 1,
                registration: .registering(
                    progress: min(1, Double(registrationPrints.count) / Double(requiredSamples))
                ),
                controllerAttention: .looking
            )))
            return
        }

        let baseline = averageGaze(registrationGazes) ?? NormalizedGaze(x: 0.5, y: 0.5)
        let profile = SessionControllerProfile(
            trackID: candidate.trackID,
            referencePrints: Array(registrationPrints.suffix(3)),
            gazeBaseline: baseline,
            matchThreshold: matchThreshold(for: registrationPrints)
        )
        controllerProfile = profile
        smoothedControllerGaze = baseline
        clearRegistrationSamples()

        emit(.multi(MultiPersonObservation(
            faceCount: 1,
            registration: .ready,
            controllerAttention: .looking
        )))
    }

    private func findController(
        profile: SessionControllerProfile,
        among faces: [TrackedFaceObservation],
        pixelBuffer: CVPixelBuffer
    ) -> TrackedFaceObservation? {
        let tracked = faces.first(where: { $0.trackID == profile.trackID })
        let shouldVerifyByAppearance = faces.count >= 2 || (analyzedFrameCount % 5 == 0)
        if let tracked, !shouldVerifyByAppearance {
            return tracked
        }

        let candidates: [(face: TrackedFaceObservation, distance: Float)] = faces.compactMap { candidate in
            guard let print = featurePrint(for: candidate.face, pixelBuffer: pixelBuffer),
                  let distance = minimumDistance(from: print, to: profile.referencePrints) else {
                return nil
            }
            return (candidate, distance)
        }.sorted { $0.distance < $1.distance }

        guard let best = candidates.first, best.distance <= profile.matchThreshold else {
            return shouldVerifyByAppearance ? nil : tracked
        }
        if candidates.count > 1, best.distance + 0.06 >= candidates[1].distance { return nil }

        profile.trackID = best.face.trackID
        return best.face
    }

    private func controllerAttention(
        for face: VNFaceObservation,
        baseline: NormalizedGaze
    ) -> AttentionSample {
        guard isHeadForward(face) else { return .turnedAway }
        guard let gaze = normalizedGaze(for: face) else { return .uncertain }

        let alpha: CGFloat = 0.32
        let previous = smoothedControllerGaze ?? gaze
        let smoothed = NormalizedGaze(
            x: previous.x + alpha * (gaze.x - previous.x),
            y: previous.y + alpha * (gaze.y - previous.y)
        )
        smoothedControllerGaze = smoothed

        return GazeGeometry.isLooking(smoothed, baseline: baseline) ? .looking : .turnedAway
    }

    private func normalizedGaze(for face: VNFaceObservation) -> NormalizedGaze? {
        guard let landmarks = face.landmarks else { return nil }
        let samples = [
            eyeRatio(eye: landmarks.leftEye, pupil: landmarks.leftPupil),
            eyeRatio(eye: landmarks.rightEye, pupil: landmarks.rightPupil)
        ].compactMap { $0 }
        guard !samples.isEmpty else { return nil }
        let count = CGFloat(samples.count)
        return NormalizedGaze(
            x: samples.reduce(0) { $0 + $1.x } / count,
            y: samples.reduce(0) { $0 + $1.y } / count
        )
    }

    private func eyeRatio(
        eye: VNFaceLandmarkRegion2D?,
        pupil: VNFaceLandmarkRegion2D?
    ) -> NormalizedGaze? {
        guard let eye, let pupil, !eye.normalizedPoints.isEmpty, !pupil.normalizedPoints.isEmpty else {
            return nil
        }
        return GazeGeometry.eyeRatio(
            eyePoints: eye.normalizedPoints,
            pupilPoints: pupil.normalizedPoints
        )
    }

    private func featurePrint(
        for face: VNFaceObservation,
        pixelBuffer: CVPixelBuffer
    ) -> VNFeaturePrintObservation? {
        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.upMirrored)
        let extent = orientedImage.extent
        var faceRect = CGRect(
            x: extent.minX + face.boundingBox.minX * extent.width,
            y: extent.minY + face.boundingBox.minY * extent.height,
            width: face.boundingBox.width * extent.width,
            height: face.boundingBox.height * extent.height
        )
        faceRect = faceRect.insetBy(dx: -faceRect.width * 0.08, dy: -faceRect.height * 0.08)
        faceRect = faceRect.intersection(extent)
        guard faceRect.width >= 24, faceRect.height >= 24 else { return nil }

        let cropped = orientedImage
            .cropped(to: faceRect)
            .transformed(by: CGAffineTransform(translationX: -faceRect.minX, y: -faceRect.minY))
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    private func matchThreshold(for prints: [VNFeaturePrintObservation]) -> Float {
        var distances: [Float] = []
        for leftIndex in prints.indices {
            for rightIndex in prints.indices where rightIndex > leftIndex {
                var distance: Float = 0
                if (try? prints[leftIndex].computeDistance(&distance, to: prints[rightIndex])) != nil {
                    distances.append(distance)
                }
            }
        }
        let baseline = distances.max() ?? 0.12
        return min(1.20, max(0.30, baseline * 3 + 0.08))
    }

    private func minimumDistance(
        from candidate: VNFeaturePrintObservation,
        to references: [VNFeaturePrintObservation]
    ) -> Float? {
        var result: Float?
        for reference in references {
            var distance: Float = 0
            guard (try? candidate.computeDistance(&distance, to: reference)) != nil else { continue }
            result = min(result ?? distance, distance)
        }
        return result
    }

    private func averageGaze(_ samples: [NormalizedGaze]) -> NormalizedGaze? {
        guard !samples.isEmpty else { return nil }
        let count = CGFloat(samples.count)
        return NormalizedGaze(
            x: samples.reduce(0) { $0 + $1.x } / count,
            y: samples.reduce(0) { $0 + $1.y } / count
        )
    }

    private func isHeadForward(_ face: VNFaceObservation) -> Bool {
        let yaw = face.yaw?.doubleValue ?? 0
        let pitch = face.pitch?.doubleValue ?? 0
        return abs(yaw) <= 0.38 && abs(pitch) <= 0.48
    }

    private func clearRegistrationSamples() {
        registrationTrackID = nil
        registrationPrints.removeAll(keepingCapacity: false)
        registrationGazes.removeAll(keepingCapacity: false)
    }

    private func resetRecognitionState() {
        tracker.reset()
        controllerProfile = nil
        smoothedControllerGaze = nil
        analyzedFrameCount = 0
        clearRegistrationSamples()
    }

    private func emit(_ update: AttentionUpdate) {
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(update)
        }
    }

    private func area(of observation: VNFaceObservation) -> CGFloat {
        observation.boundingBox.width * observation.boundingBox.height
    }
}

private struct TrackedFaceObservation {
    let face: VNFaceObservation
    let trackID: Int
}

private final class SessionControllerProfile {
    var trackID: Int
    let referencePrints: [VNFeaturePrintObservation]
    let gazeBaseline: NormalizedGaze
    let matchThreshold: Float

    init(
        trackID: Int,
        referencePrints: [VNFeaturePrintObservation],
        gazeBaseline: NormalizedGaze,
        matchThreshold: Float
    ) {
        self.trackID = trackID
        self.referencePrints = referencePrints
        self.gazeBaseline = gazeBaseline
        self.matchThreshold = matchThreshold
    }
}

struct SessionFaceTracker {
    private struct Track {
        let id: Int
        var bounds: CGRect
        var missedFrames: Int
    }

    private var tracks: [Track] = []
    private var nextID = 1

    mutating func update(_ detections: [CGRect]) -> [Int] {
        tracks.indices.forEach { tracks[$0].missedFrames += 1 }

        var assignments = Array<Int?>(repeating: nil, count: detections.count)
        var usedTracks = Set<Int>()
        let pairs = tracks.indices.flatMap { trackIndex in
            detections.indices.map { detectionIndex in
                (
                    trackIndex: trackIndex,
                    detectionIndex: detectionIndex,
                    cost: matchCost(tracks[trackIndex].bounds, detections[detectionIndex])
                )
            }
        }.filter { $0.cost < 1.15 }.sorted { $0.cost < $1.cost }

        for pair in pairs where assignments[pair.detectionIndex] == nil && !usedTracks.contains(pair.trackIndex) {
            tracks[pair.trackIndex].bounds = detections[pair.detectionIndex]
            tracks[pair.trackIndex].missedFrames = 0
            assignments[pair.detectionIndex] = tracks[pair.trackIndex].id
            usedTracks.insert(pair.trackIndex)
        }

        for index in detections.indices where assignments[index] == nil {
            let id = nextID
            nextID += 1
            tracks.append(Track(id: id, bounds: detections[index], missedFrames: 0))
            assignments[index] = id
        }

        tracks.removeAll { $0.missedFrames > 8 }
        return assignments.map { $0 ?? 0 }
    }

    mutating func reset() {
        tracks.removeAll(keepingCapacity: false)
        nextID = 1
    }

    private func matchCost(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = left.width * left.height + right.width * right.height - intersectionArea
        let overlap = unionArea > 0 ? intersectionArea / unionArea : 0
        let deltaX = left.midX - right.midX
        let deltaY = left.midY - right.midY
        let centerDistance = hypot(deltaX, deltaY)
        let scale = max(0.05, (hypot(left.width, left.height) + hypot(right.width, right.height)) / 2)
        return 0.68 * (1 - overlap) + 0.32 * min(2, centerDistance / scale)
    }
}
