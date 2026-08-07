enum LongRunningChargeSession: Equatable, Sendable {
    case topUp(returnLimit: Int)
    case discharge(target: Int, returnLimit: Int)

    var expectedMode: ChargeMode {
        switch self {
        case .topUp(let returnLimit):
            return .toppingUp(returnLimit: returnLimit)
        case .discharge(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        }
    }

    var returnLimit: Int {
        switch self {
        case .topUp(let returnLimit), .discharge(_, let returnLimit):
            return returnLimit
        }
    }

}

enum LongRunningProgressDecision: Equatable, Sendable {
    case none
    case checkLiveness(LongRunningChargeSession)
    case finishAndRestoreMaintain(LongRunningChargeSession)
}

enum LongRunningExitDecision: Equatable, Sendable {
    case recoverMaintain(LongRunningChargeSession)
    case externalDrift(expected: ReconciledChargeExpectation, observed: ObservedChargeMode)
}

enum LongRunningChargePolicy {
    static func progress(mode: ChargeMode, currentCharge: Int?) -> LongRunningProgressDecision {
        guard let session = session(from: mode) else { return .none }
        guard let currentCharge, (0...100).contains(currentCharge) else {
            return .checkLiveness(session)
        }

        switch session {
        case .topUp:
            return currentCharge >= 100
                ? .finishAndRestoreMaintain(session)
                : .checkLiveness(session)
        case .discharge(let target, _):
            return currentCharge <= target
                ? .finishAndRestoreMaintain(session)
                : .checkLiveness(session)
        }
    }

    static func unexpectedExit(
        session: LongRunningChargeSession,
        observed: ObservedChargeMode
    ) -> LongRunningExitDecision {
        if observed == .chargingDisabled {
            return .recoverMaintain(session)
        }
        return .externalDrift(
            expected: .maintaining(limit: session.returnLimit),
            observed: observed
        )
    }

    static func session(from mode: ChargeMode) -> LongRunningChargeSession? {
        switch mode {
        case .toppingUp(let returnLimit):
            return .topUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharge(target: target, returnLimit: returnLimit)
        default:
            return nil
        }
    }
}
