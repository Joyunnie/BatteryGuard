// HeatProtection.swift
// 발열 보호 기능
//
// 배터리 온도 센서(TB0T, TB1T, TB2T)를 SMC를 통해 모니터링.
// 임계값(기본 40도C) 초과 시 충전 억제 (inhibitCharging).
// 온도가 임계값-2도C 이하로 내려오면 충전 복원 (allowCharging).
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

    func check(batteryInfo: BatteryInfo) throws -> Bool {
        guard settings.heatProtectionEnabled else {
            if isTriggered {
                try smc.allowCharging()
                isTriggered = false
            }
            return false
        }

        let smcTemp = try smc.readBatteryTemperature()
        lastTemperature = max(Double(smcTemp), batteryInfo.temperature)

        let threshold = settings.heatProtectionThreshold

        if lastTemperature > threshold && !isTriggered {
            try smc.inhibitCharging()
            isTriggered = true
            print("[HeatProtection] \(String(format: "%.1f", lastTemperature))°C > \(threshold)°C → inhibit")
            return true
        } else if lastTemperature <= (threshold - 2.0) && isTriggered {
            try smc.allowCharging()
            isTriggered = false
            print("[HeatProtection] temp normal → allow")
            return false
        }

        return isTriggered
    }
}
