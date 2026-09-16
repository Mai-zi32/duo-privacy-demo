import Foundation

enum AttentionGateAction: Equatable {
    case none
    case cover
    case reveal
}

final class AttentionGate {
    private let awayDelay: TimeInterval
    private let returnDelay: TimeInterval
    private var awaySince: TimeInterval?
    private var returnSince: TimeInterval?
    private(set) var isCovered = false

    init(awayDelay: TimeInterval = 1.5, returnDelay: TimeInterval = 0.35) {
        self.awayDelay = awayDelay
        self.returnDelay = returnDelay
    }

    func update(sample: AttentionSample, at now: TimeInterval) -> AttentionGateAction {
        switch sample {
        case .looking:
            awaySince = nil
            if returnSince == nil { returnSince = now }
            guard isCovered,
                  let returnSince,
                  now - returnSince >= returnDelay else {
                return .none
            }
            isCovered = false
            return .reveal

        case .turnedAway, .absent:
            returnSince = nil
            if awaySince == nil { awaySince = now }
            guard !isCovered,
                  let awaySince,
                  now - awaySince >= awayDelay else {
                return .none
            }
            isCovered = true
            return .cover

        case .uncertain:
            return .none
        }
    }

    func reset(covered: Bool = false) {
        awaySince = nil
        returnSince = nil
        isCovered = covered
    }
}

enum LogicSelfTest {
    static func run() -> Bool {
        let gate = AttentionGate(awayDelay: 1.5, returnDelay: 0.35)
        let checks: [(AttentionGateAction, AttentionGateAction)] = [
            (gate.update(sample: .looking, at: 0.0), .none),
            (gate.update(sample: .turnedAway, at: 1.0), .none),
            (gate.update(sample: .turnedAway, at: 2.4), .none),
            (gate.update(sample: .turnedAway, at: 2.5), .cover),
            (gate.update(sample: .looking, at: 3.0), .none),
            (gate.update(sample: .looking, at: 3.34), .none),
            (gate.update(sample: .looking, at: 3.40), .reveal)
        ]
        guard checks.allSatisfy({ $0.0 == $0.1 }) else { return false }

        let multi = MultiPersonAttentionGate(awayDelay: 1.5, returnDelay: 0.35)
        let waiting = MultiPersonObservation(
            faceCount: 1,
            registration: .ready,
            controllerAttention: .absent
        )
        guard multi.update(waiting, at: 0) == .none, !multi.isArmed else { return false }

        let armedLooking = MultiPersonObservation(
            faceCount: 2,
            registration: .ready,
            controllerAttention: .looking
        )
        guard multi.update(armedLooking, at: 1) == .none, multi.isArmed else { return false }

        let aloneAway = MultiPersonObservation(
            faceCount: 1,
            registration: .ready,
            controllerAttention: .turnedAway
        )
        guard multi.update(aloneAway, at: 2) == .none else { return false }
        guard multi.update(aloneAway, at: 3.5) == .cover, multi.isCovered else { return false }

        let otherOnly = MultiPersonObservation(
            faceCount: 1,
            registration: .ready,
            controllerAttention: nil
        )
        guard multi.update(otherOnly, at: 4) == .none, multi.isCovered, multi.isArmed else { return false }

        let controllerReturned = MultiPersonObservation(
            faceCount: 1,
            registration: .ready,
            controllerAttention: .looking
        )
        guard multi.update(controllerReturned, at: 5) == .none else { return false }
        guard multi.update(controllerReturned, at: 5.4) == .reveal, !multi.isCovered else { return false }

        let eye = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)
        ]
        guard let centered = GazeGeometry.eyeRatio(
            eyePoints: eye,
            pupilPoints: [CGPoint(x: 0.5, y: 0.5)]
        ), GazeGeometry.isLooking(centered, baseline: NormalizedGaze(x: 0.5, y: 0.5)) else {
            return false
        }
        guard let shifted = GazeGeometry.eyeRatio(
            eyePoints: eye,
            pupilPoints: [CGPoint(x: 0.9, y: 0.5)]
        ), !GazeGeometry.isLooking(shifted, baseline: NormalizedGaze(x: 0.5, y: 0.5)) else {
            return false
        }

        var tracker = SessionFaceTracker()
        let left = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3)
        let right = CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.3)
        let initialIDs = tracker.update([left, right])
        let reorderedIDs = tracker.update([
            right.offsetBy(dx: -0.01, dy: 0),
            left.offsetBy(dx: 0.01, dy: 0)
        ])
        guard initialIDs.count == 2,
              reorderedIDs == [initialIDs[1], initialIDs[0]] else {
            return false
        }

        let missingPermissions = RequiredPermissionState(
            camera: .notDetermined,
            screenRecording: .denied
        )
        let grantedPermissions = RequiredPermissionState(
            camera: .authorized,
            screenRecording: .authorized
        )
        guard !missingPermissions.isReady, grantedPermissions.isReady else { return false }

        multi.reset()
        return !multi.isArmed && !multi.isCovered
    }
}
