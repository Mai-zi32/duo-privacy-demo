import CoreGraphics
import Foundation

enum PrivacyMode: String, CaseIterable {
    case singlePerson
    case multiPerson

    var title: String {
        switch self {
        case .singlePerson: return "单人模式"
        case .multiPerson: return "多人模式"
        }
    }
}

enum AttentionSample: Equatable {
    case looking
    case turnedAway
    case absent
    case uncertain
}

enum ControllerRegistrationState: Equatable {
    case needsSingleFace
    case registering(progress: Double)
    case ready
}

struct MultiPersonObservation: Equatable {
    let faceCount: Int
    let registration: ControllerRegistrationState
    let controllerAttention: AttentionSample?
}

enum AttentionUpdate: Equatable {
    case single(AttentionSample)
    case multi(MultiPersonObservation)
}

struct NormalizedGaze: Equatable {
    let x: CGFloat
    let y: CGFloat
}

enum GazeGeometry {
    static func eyeRatio(eyePoints: [CGPoint], pupilPoints: [CGPoint]) -> NormalizedGaze? {
        guard !eyePoints.isEmpty, !pupilPoints.isEmpty,
              let minX = eyePoints.map(\.x).min(),
              let maxX = eyePoints.map(\.x).max(),
              let minY = eyePoints.map(\.y).min(),
              let maxY = eyePoints.map(\.y).max(),
              maxX - minX > 0.001,
              maxY - minY > 0.001 else {
            return nil
        }
        let pupilCount = CGFloat(pupilPoints.count)
        let pupilCenter = CGPoint(
            x: pupilPoints.reduce(0) { $0 + $1.x } / pupilCount,
            y: pupilPoints.reduce(0) { $0 + $1.y } / pupilCount
        )
        return NormalizedGaze(
            x: (pupilCenter.x - minX) / (maxX - minX),
            y: (pupilCenter.y - minY) / (maxY - minY)
        )
    }

    static func isLooking(_ gaze: NormalizedGaze, baseline: NormalizedGaze) -> Bool {
        abs(gaze.x - baseline.x) <= 0.13 && abs(gaze.y - baseline.y) <= 0.16
    }
}
