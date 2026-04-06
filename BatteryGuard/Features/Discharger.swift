// Discharger.swift
// 방전 기능 (충전기 연결 상태에서 배터리로만 구동)
//
// CHIE=08은 CHTE=00000000 (충전 허용 상태)에서만 작동.
// CHTE=01000000과 CHIE=08을 동시에 설정하면 CHIE가 무효화됨.
//
// 시작 시퀀스:
//   1. CHIE=00 (리셋) → 0.5s
//   2. CHTE=00000000 (충전 회로 기본 상태) → 0.5s
//   3. CHIE=08 (방전 활성화)
//
// 방전 중에는 ChargeLimiter가 CHTE를 건드리면 안 됨.
// 제어 루프에서 isDischarging일 때 ChargeLimiter를 skip.

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

        // Step 1: 기존 방전 상태 리셋
        try smc.disableForceDischarge()
        Thread.sleep(forTimeInterval: 0.5)

        // Step 2: 충전 회로를 기본 상태로 (CHTE=00000000)
        // CHIE=08은 CHTE=00000000에서만 작동함
        try smc.allowCharging()
        Thread.sleep(forTimeInterval: 0.5)

        // Step 3: 방전 활성화 — inhibitCharging 호출하지 않음!
        try smc.enableForceDischarge()

        isActive = true
        print("[Discharger] force discharge started (CHTE=00, CHIE=08)")
    }

    func stop() throws {
        guard isActive else { return }

        // 방전 해제 후 충전 회로 기본 상태로 복원
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
