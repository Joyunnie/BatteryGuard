// Discharger.swift
// 방전 기능 (충전기 연결 상태에서 배터리로만 구동)
//
// Apple Silicon force discharge keys:
//   ON:  CH0I=0x01, CHIE=0x08, CH0J=0x01
//   OFF: CH0I=0x00, CHIE=0x00, CH0J=0x00
// 추가로 충전도 inhibit해야 방전만 진행됨.

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
        try smc.inhibitCharging()
        try smc.enableForceDischarge()
        isActive = true
        print("[Discharger] force discharge started")
    }

    func stop() throws {
        guard isActive else { return }
        try smc.disableForceDischarge()
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
