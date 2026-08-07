import Foundation

enum ChargeShutdownPolicy: Equatable, Sendable {
    case preserveMaintain
    case preserveReleasedControl
    case releaseControl
    case restoreMaintain(Int)
    case keepChargingDisabled
}

struct ChargeShutdownContext: Equatable, Sendable {
    let ownership: BatteryControlOwnership
    let mode: ChargeMode
    let effectiveLimit: Int
}

enum ChargeShutdownPlanningError: LocalizedError, Equatable, Sendable {
    case unsafeExternalState(ObservedChargeMode)
    case releasedControlMismatch(BatteryControlStatus)
    case manualInterventionRequired(String)

    var errorDescription: String? {
        switch self {
        case .unsafeExternalState(let observed):
            return "외부 CLI 변경 상태를 먼저 해결해야 안전하게 종료할 수 있습니다: \(observed.userDescription)"
        case .releasedControlMismatch(let status):
            return "BatteryGuard control was no longer released: \(status.diagnosticDescription)"
        case .manualInterventionRequired(let message):
            return "하드웨어 상태가 불확실하여 자동 종료 복구를 수행하지 않습니다: \(message)"
        }
    }
}

enum ChargeShutdownPlanner {
    static func requestedPolicy(for context: ChargeShutdownContext) throws -> ChargeShutdownPolicy {
        switch context.ownership {
        case .releasing:
            return .releaseControl
        case .system:
            return .preserveReleasedControl
        case .batteryGuard:
            break
        }

        switch context.mode {
        case .controlDisabled:
            return .preserveReleasedControl
        case .toppingUp(let limit), .discharging(_, let limit):
            return .restoreMaintain(limit)
        case .transitioning(let transition):
            switch transition {
            case .enteringHeat, .restoringHeat:
                return .keepChargingDisabled
            case .preparingForSleep(let previous):
                return .restoreMaintain(previous.maintainLimit)
            case .releasingControl:
                return .releaseControl
            default:
                return .restoreMaintain(
                    transition.previousMode?.maintainLimit ?? context.effectiveLimit
                )
            }
        case .heatBlocked, .failed(_, _, .heatProtection):
            return .keepChargingDisabled
        case .sleepProtected(let previous, _):
            return .restoreMaintain(previous.maintainLimit)
        case .failed(_, let message, .manualIntervention):
            throw ChargeShutdownPlanningError.manualInterventionRequired(message)
        case .externalDrift(_, let observed):
            switch observed {
            case .maintaining:
                return .preserveMaintain
            case .chargingDisabled:
                return .keepChargingDisabled
            case .charging, .discharging, .unavailable, .inconsistent:
                throw ChargeShutdownPlanningError.unsafeExternalState(observed)
            }
        case .idle, .maintaining, .failed(_, _, .recoverPrevious):
            return .preserveMaintain
        }
    }

    static func verifiedPolicy(
        requested: ChargeShutdownPolicy,
        status: BatteryControlStatus,
        restoreLimit: Int
    ) throws -> ChargeShutdownPolicy {
        if case .preserveMaintain = requested,
           let actualLimit = status.maintainLevel,
           status.isVerifiedMaintain(level: actualLimit) {
            return .preserveMaintain
        }

        switch requested {
        case .keepChargingDisabled:
            return .keepChargingDisabled
        case .preserveReleasedControl:
            guard status.isCompatibleWithReleasedControl else {
                throw ChargeShutdownPlanningError.releasedControlMismatch(status)
            }
            return .preserveReleasedControl
        case .releaseControl:
            return .releaseControl
        case .preserveMaintain:
            return .restoreMaintain(restoreLimit)
        case .restoreMaintain(let recordedLimit):
            return .restoreMaintain(recordedLimit)
        }
    }
}
