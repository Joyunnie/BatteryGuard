// SleepChargingProtection.swift
// Pure policy and test seams for lid-close charging protection.

import Foundation

enum SleepChargingStrategy: String, CaseIterable, Hashable, Sendable {
    case disabled
    case pauseOnSleep
    case finishChargingThenSleep

    var title: String {
        switch self {
        case .disabled: return "사용 안 함"
        case .pauseOnSleep: return "잠들기 전 충전 중지"
        case .finishChargingThenSleep: return "한도까지 충전 후 잠자기"
        }
    }
}

enum SleepInhibitionOwnership: Equatable, Sendable {
    case none
    case batteryGuard
    case external
}

enum SleepChargingProtectionState: Equatable {
    case inactive
    case ready
    case holdingAwake(limit: Int, ownership: SleepInhibitionOwnership)
    case pausedForSleep(charge: Int?)
    case unavailable(String)

    var userDescription: String? {
        switch self {
        case .inactive:
            return nil
        case .ready:
            return "뚜껑을 닫으면 충전을 먼저 안전하게 중지합니다."
        case .holdingAwake(let limit, .batteryGuard):
            return "\(limit)%까지 충전한 뒤 충전을 확인하고 잠자기를 허용합니다."
        case .holdingAwake(let limit, .external):
            return "시스템 잠자기가 외부에서 이미 비활성화되어 있습니다. BatteryGuard는 \(limit)% 제한만 감시하며 외부 설정을 해제하지 않습니다."
        case .holdingAwake(let limit, .none):
            return "\(limit)%까지 충전하기 위한 잠자기 보호를 준비 중입니다."
        case .pausedForSleep(let charge):
            return charge.map { "잠자기 전 \($0)%에서 충전을 중지했습니다." }
                ?? "잠자기 전 충전을 중지했습니다."
        case .unavailable(let message):
            return "잠자기 충전 보호를 사용할 수 없습니다: \(message)"
        }
    }
}

enum AwakeSleepProtectionAction: Equatable {
    case none
    case acquire(limit: Int)
    case verifyLimitThenRelease(limit: Int)
    case release
}

enum SleepChargingPolicy {
    static func awakeAction(
        strategy: SleepChargingStrategy,
        ownsBatteryControl: Bool,
        mode: ChargeMode,
        charge: Int,
        isPluggedIn: Bool,
        inhibitionOwnership: SleepInhibitionOwnership,
        operationPending: Bool
    ) -> AwakeSleepProtectionAction {
        guard inhibitionOwnership != .batteryGuard || strategy == .finishChargingThenSleep else {
            return .release
        }
        guard strategy == .finishChargingThenSleep,
              ownsBatteryControl,
              isPluggedIn,
              !operationPending,
              case .maintaining(let limit) = mode else {
            return inhibitionOwnership == .batteryGuard ? .release : .none
        }
        if charge < limit {
            return .acquire(limit: limit)
        }
        return inhibitionOwnership == .batteryGuard
            ? .verifyLimitThenRelease(limit: limit)
            : .none
    }
}

protocol SystemSleepInhibiting: AnyObject, Sendable {
    func prepare() async throws
    func acquire(until limit: Int, maximumDuration: TimeInterval) async throws -> SleepInhibitionOwnership
    func releaseOwnedInhibition() async throws
}

enum SleepInhibitionError: LocalizedError, Equatable {
    case maximumDurationExceeded

    var errorDescription: String? {
        "잠자기 보류 최대 시간이 지나 충전을 중지하고 시스템 잠자기를 복원했습니다."
    }
}
