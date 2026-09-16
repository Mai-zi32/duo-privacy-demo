import Foundation

final class MultiPersonAttentionGate {
    private let awayDelay: TimeInterval
    private let returnDelay: TimeInterval
    private var awaySince: TimeInterval?
    private var returnSince: TimeInterval?

    private(set) var isArmed = false
    private(set) var isCovered = false

    init(awayDelay: TimeInterval = 1.5, returnDelay: TimeInterval = 0.35) {
        self.awayDelay = awayDelay
        self.returnDelay = returnDelay
    }

    func update(_ observation: MultiPersonObservation, at now: TimeInterval) -> AttentionGateAction {
        guard observation.registration == .ready else {
            awaySince = nil
            returnSince = nil
            return .none
        }

        if !isArmed {
            guard observation.faceCount >= 2 else { return .none }
            isArmed = true
        }

        switch observation.controllerAttention ?? .absent {
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

    func reset() {
        awaySince = nil
        returnSince = nil
        isArmed = false
        isCovered = false
    }

    func dismissCoverPreservingArmed() {
        awaySince = nil
        returnSince = nil
        isCovered = false
    }
}
