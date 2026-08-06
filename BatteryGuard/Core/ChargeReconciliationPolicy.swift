import Foundation

struct ChargeReconciliationSnapshot: Sendable {
    let status: BatteryControlStatus
    let ownsLongRunningOperation: Bool?
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
            return snapshot.ownsLongRunningOperation == true &&
                status.charging == .enabled &&
                status.isDischarging == false &&
                status.maintainWorker.isStopped
        case .discharging:
            return snapshot.ownsLongRunningOperation == true &&
                status.charging == .disabled &&
                status.isDischarging == true &&
                status.maintainWorker.isStopped
        case .chargingDisabled:
            return status.isVerifiedChargingDisabled
        case .controlReleasing:
            return false
        case .controlReleased:
            return snapshot.ownsLongRunningOperation != true &&
                status.isCompatibleWithReleasedControl
        }
    }

    static func observedMode(from status: BatteryControlStatus) -> ObservedChargeMode {
        if status.isDischarging == true,
           status.charging == .disabled,
           status.maintainWorker.isStopped {
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

    static func mode(from expectation: ReconciledChargeExpectation) -> ChargeMode {
        switch expectation {
        case .controlReleasing:
            return .externalDrift(
                expected: expectation,
                observed: .unavailable("BatteryGuard control release is still pending")
            )
        case .controlReleased(let lastLimit): return .controlDisabled(lastLimit: lastLimit)
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .chargingDisabled(let previous): return .heatBlocked(previous: previous)
        }
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
