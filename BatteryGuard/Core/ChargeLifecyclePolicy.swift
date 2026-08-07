import Foundation

enum ChargeShutdownPolicy: Equatable, Sendable {
    case preserveMaintain
    case preserveReleasedControl
    case releaseControl
    case restoreMaintain(Int)
    case keepChargingDisabled
}

struct ChargeShutdownContext: Equatable, Sendable {
    let releasePending: Bool
    let controlEnabled: Bool
    let mode: ChargeMode
    let effectiveLimit: Int
}

enum ChargeShutdownPlanningError: LocalizedError, Equatable, Sendable {
    case unsafeExternalState(ObservedChargeMode)
    case releasedControlMismatch(String)

    var errorDescription: String? {
        switch self {
        case .unsafeExternalState(let observed):
            return "외부 CLI 변경 상태를 먼저 해결해야 안전하게 종료할 수 있습니다: \(observed.userDescription)"
        case .releasedControlMismatch(let description):
            return "BatteryGuard control was no longer released: \(description)"
        }
    }
}

enum ChargeShutdownPlanner {
    static func requestedPolicy(for context: ChargeShutdownContext) throws -> ChargeShutdownPolicy {
        if context.releasePending { return .releaseControl }
        if !context.controlEnabled { return .preserveReleasedControl }

        switch context.mode {
        case .controlDisabled:
            return .preserveReleasedControl
        case .toppingUp(let limit), .discharging(_, let limit):
            return .restoreMaintain(limit)
        case .transitioning(let transition):
            switch transition {
            case .enteringHeat, .restoringHeat:
                return .keepChargingDisabled
            case .releasingControl:
                return .releaseControl
            default:
                return .restoreMaintain(
                    transition.previousMode?.maintainLimit ?? context.effectiveLimit
                )
            }
        case .heatBlocked, .failed(_, _, true):
            return context.releasePending ? .releaseControl : .keepChargingDisabled
        case .externalDrift(_, let observed):
            switch observed {
            case .maintaining:
                return .preserveMaintain
            case .chargingDisabled:
                return .keepChargingDisabled
            case .charging, .discharging, .unavailable, .inconsistent:
                throw ChargeShutdownPlanningError.unsafeExternalState(observed)
            }
        case .idle, .maintaining, .failed:
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
                throw ChargeShutdownPlanningError.releasedControlMismatch(
                    status.diagnosticDescription
                )
            }
            return .preserveReleasedControl
        case .releaseControl:
            return .releaseControl
        case .preserveMaintain, .restoreMaintain:
            return .restoreMaintain(restoreLimit)
        }
    }
}
