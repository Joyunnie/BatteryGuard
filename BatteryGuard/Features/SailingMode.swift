// SailingMode.swift
// 세일링 모드 (Apple Silicon)
//
// 상한/하한 범위 내에서 자연 방전을 허용.
//   charge >= upper → inhibitCharging (자연 방전 대기)
//   charge <= lower → allowCharging (상한까지 충전)
//   중간 범위 → 현재 상태 유지
//
// 능동적으로 방전시키지 않음. 셀 자가 방전과 시스템 부하 초과만 이용.

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
                try smc.inhibitCharging()
                currentState = .drifting
                print("[SailingMode] \(currentCharge)% >= \(upper)% → drift")
            } else {
                try smc.allowCharging()
            }

        case .drifting:
            if currentCharge <= lower {
                try smc.allowCharging()
                currentState = .charging
                print("[SailingMode] \(currentCharge)% <= \(lower)% → charge")
            }
            // drifting 중엔 inhibit 상태 유지 (아무것도 안 함)
        }
    }

    func reset() {
        currentState = .drifting
    }
}
