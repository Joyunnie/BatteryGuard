// SailingMode.swift
// 세일링 모드
//
// 일반 Charge Limiter는 정확히 한 지점(예: 80%)에 배터리를 유지하려 함.
// 이 과정에서 미세 충방전이 반복됨 (micro-cycling).
//
// Sailing Mode는 이 범위를 넓힘:
//   예) 상한 80%, 하한 75%:
//   80% 도달 -> 충전 중지 -> 자연 방전 대기 -> 75% 도달 -> 충전 재개 -> 80%
//
// 능동적으로 방전시키지 않음. 자연 방전(셀 자가 방전, 시스템 부하 초과)만 허용.
// BCLM 값을 동적으로 조정하여 구현.

import Foundation

final class SailingMode {
    private let smc: SMCKit
    private let monitor: BatteryMonitor
    private let settings: UserSettings

    enum State {
        case drifting    // 상한 도달 후 자연 방전 대기 중
        case charging    // 하한 도달 후 충전 중
    }

    private(set) var currentState: State = .drifting

    init(smc: SMCKit, monitor: BatteryMonitor, settings: UserSettings) {
        self.smc = smc
        self.monitor = monitor
        self.settings = settings
    }

    func apply(batteryInfo: BatteryInfo) throws {
        guard settings.sailingEnabled else { return }

        let upper = settings.chargeLimit
        let lower = settings.sailingLowerBound
        guard lower < upper, lower >= 20 else { return }

        let currentCharge = batteryInfo.currentCharge

        switch currentState {
        case .charging:
            if currentCharge >= upper {
                try smc.writeChargeLimit(UInt8(currentCharge))
                currentState = .drifting
            } else {
                try smc.writeChargeLimit(UInt8(upper))
            }

        case .drifting:
            if currentCharge <= lower {
                try smc.writeChargeLimit(UInt8(upper))
                currentState = .charging
            } else {
                try smc.writeChargeLimit(UInt8(max(currentCharge, lower)))
            }
        }
    }

    func reset() {
        currentState = .drifting
    }
}
