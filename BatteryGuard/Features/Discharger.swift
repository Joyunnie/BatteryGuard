// Discharger.swift
// 방전 기능 (충전기 연결 상태에서 배터리로만 구동)
//
// battery script의 "adapter off" 시퀀스를 재현:
//   1. disableForceDischarge (CHIE=00) — 리셋
//   2. allowCharging (CHTE=00000000) — 리셋
//   3. inhibitCharging (CHTE=01000000) — 충전 차단
//   4. enableForceDischarge (CHIE=08) — 방전 활성화
// 각 단계 사이 0.5초 대기. SMC가 전력 경로를 전환하는 데 시간 필요.

import Foundation

final class Discharger {
    private let smc: SMCKit
    private let monitor: BatteryMonitor
    private let settings: UserSettings

    private(set) var isActive = false

    init(smc: SMCKit, monitor: BatteryMonitor, settings: UserSettings) {
        self.smc = smc
        self.monitor = monitor
        self.settings = settings
    }

    func start() throws {
        guard !isActive else { return }

        // Step 1: 리셋 — 기존 방전 상태 초기화
        try smc.disableForceDischarge()
        Thread.sleep(forTimeInterval: 0.5)

        // Step 2: 리셋 — 충전 상태 초기화
        try smc.allowCharging()
        Thread.sleep(forTimeInterval: 0.5)

        // Step 3: 충전 차단
        try smc.inhibitCharging()
        Thread.sleep(forTimeInterval: 0.5)

        // Step 4: 방전 활성화
        try smc.enableForceDischarge()

        isActive = true
        print("[Discharger] force discharge started (full sequence)")
    }

    func stop() throws {
        guard isActive else { return }

        try smc.disableForceDischarge()
        Thread.sleep(forTimeInterval: 0.5)
        try smc.allowCharging()

        isActive = false
        print("[Discharger] force discharge stopped")
    }

    func startInClamshell() throws {
        _ = monitor.preventSleep(reason: "BatteryGuard: Discharge in Clamshell Mode")
        try start()
    }

    func stopFromClamshell() throws {
        try stop()
        monitor.allowSleep()
    }
}
