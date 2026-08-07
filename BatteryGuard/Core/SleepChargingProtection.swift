// SleepChargingProtection.swift
// Pure policy for the verified charging-off transition before system sleep.

import Foundation

enum SleepChargingStrategy: String, CaseIterable, Hashable, Sendable {
    case disabled
    case pauseOnSleep

    var title: String {
        switch self {
        case .disabled: return "사용 안 함"
        case .pauseOnSleep: return "잠들기 전 충전 중지"
        }
    }
}

enum SleepChargingProtectionState: Equatable {
    case inactive
    case ready
    case pausedForSleep(charge: Int?)
    case unavailable(String)

    var userDescription: String? {
        switch self {
        case .inactive:
            return nil
        case .ready:
            return "뚜껑을 닫으면 충전을 먼저 안전하게 중지합니다."
        case .pausedForSleep(let charge):
            return charge.map { "잠자기 전 \($0)%에서 충전을 중지했습니다." }
                ?? "잠자기 전 충전을 중지했습니다."
        case .unavailable(let message):
            return "잠자기 충전 보호를 사용할 수 없습니다: \(message)"
        }
    }
}

enum SleepPreparationAction: Equatable {
    case allowWithoutMutation
    case rejectWithoutMutation
    case verifyAlreadyProtected
    case stopCharging(previous: RestorableChargeMode)
}

enum SleepChargingPolicy {
    static func preparationAction(
        strategy: SleepChargingStrategy,
        ownsBatteryControl: Bool,
        mode: ChargeMode,
        effectiveLimit: Int
    ) -> SleepPreparationAction {
        guard strategy == .pauseOnSleep else { return .allowWithoutMutation }
        guard ownsBatteryControl else { return .allowWithoutMutation }

        switch mode {
        case .maintaining, .toppingUp, .discharging:
            return .stopCharging(
                previous: mode.restorableMode ?? .maintaining(limit: effectiveLimit)
            )
        case .heatBlocked:
            // Heat Protection already owns a verified charging-off state. Do not
            // relabel it as sleep protection or a later quit could restore charge.
            return .verifyAlreadyProtected
        case .sleepProtected:
            return .verifyAlreadyProtected
        case .transitioning(let transition):
            switch transition {
            case .releasingControl, .preparingForSleep:
                return .rejectWithoutMutation
            default:
                return .stopCharging(
                    previous: transition.previousMode ?? .maintaining(limit: effectiveLimit)
                )
            }
        case .idle, .controlDisabled, .externalDrift, .failed:
            // Never turn an observed Terminal change or an uncertain failure into
            // an implicit BatteryGuard-owned mutation merely because sleep begins.
            return .rejectWithoutMutation
        }
    }
}
