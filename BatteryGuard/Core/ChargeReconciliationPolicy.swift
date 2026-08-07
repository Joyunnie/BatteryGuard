enum OwnedLongRunningOperationObservation: Equatable, Sendable {
    case notRequired
    case active
    case inactive
}

struct ChargeReconciliationSnapshot: Sendable {
    let status: BatteryControlStatus
    let ownedLongRunningOperation: OwnedLongRunningOperationObservation
}

enum ChargeReconciliationPolicy {
    static func status(
        _ snapshot: ChargeReconciliationSnapshot,
        matches expectation: ReconciledChargeExpectation
    ) -> Bool {
        let status = snapshot.status
        switch expectation {
        case .maintaining(let limit):
            return status.isVerifiedMaintain(level: limit)
        case .toppingUp:
            return snapshot.ownedLongRunningOperation == .active &&
                status.charging == .enabled &&
                status.isDischarging == false &&
                status.maintainWorker.isStopped
        case .discharging:
            return snapshot.ownedLongRunningOperation == .active &&
                status.isVerifiedDischarging
        case .chargingDisabled:
            return status.isVerifiedChargingDisabled
        case .controlReleasing:
            return false
        case .controlReleased:
            return snapshot.ownedLongRunningOperation == .inactive &&
                status.isCompatibleWithReleasedControl
        }
    }

    static func observedMode(from status: BatteryControlStatus) -> ObservedChargeMode {
        if status.isVerifiedDischarging {
            return .discharging
        }
        if status.charging == .enabled,
           status.isDischarging == false,
           status.maintainWorker.isStopped {
            return .charging
        }
        if let limit = status.maintainLevel,
           ChargeControlConstraints.limitRange.contains(limit),
           status.isVerifiedMaintain(level: limit) {
            return .maintaining(limit: limit)
        }
        if status.charging == .disabled,
           status.isDischarging == false,
           status.maintainWorker.isStopped {
            return .chargingDisabled
        }
        return .inconsistent(status.diagnosticDescription)
    }

    static func expectation(fromActiveMode mode: ChargeMode) -> ReconciledChargeExpectation? {
        switch mode {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        default: return nil
        }
    }

    static func expectation(from mode: RestorableChargeMode) -> ReconciledChargeExpectation {
        switch mode {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        }
    }
}
