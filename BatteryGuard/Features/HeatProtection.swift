// HeatProtection.swift
// 발열 보호 기능
//
// 배터리 온도 센서(TB0T, TB1T, TB2T)를 SMC를 통해 모니터링.
// 임계값(기본 40도C) 초과 시 BCLM을 현재 잔량으로 설정하여 충전 차단.
// 온도가 임계값-2도C 이하로 내려오면 원래 Charge Limit으로 복원.
// 2도C 히스테리시스로 ON/OFF 진동 방지.

import Foundation

final class HeatProtection {
    private let smc: SMCKit
    private let monitor: BatteryMonitor
    private let settings: UserSettings

    private(set) var isTriggered = false
    private(set) var lastTemperature: Double = 0

    init(smc: SMCKit, monitor: BatteryMonitor, settings: UserSettings) {
        self.smc = smc
        self.monitor = monitor
        self.settings = settings
    }

    /// Heat Protection 체크 (제어 루프에서 호출)
    /// - Returns: true면 충전 차단 중
    func check(batteryInfo: BatteryInfo) throws -> Bool {
        guard settings.heatProtectionEnabled else {
            if isTriggered { isTriggered = false }
            return false
        }

        let smcTemp = try smc.readBatteryTemperature()
        lastTemperature = max(Double(smcTemp), batteryInfo.temperature)

        let threshold = settings.heatProtectionThreshold

        if lastTemperature > threshold && !isTriggered {
            try smc.writeChargeLimit(UInt8(max(20, batteryInfo.currentCharge)))
            isTriggered = true
            return true
        } else if lastTemperature <= (threshold - 2.0) && isTriggered {
            try smc.writeChargeLimit(UInt8(settings.chargeLimit))
            isTriggered = false
            return false
        }

        return isTriggered
    }
}
