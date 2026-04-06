// Discharger.swift
// 방전 기능 (충전기 연결 상태에서 배터리로만 구동)
//
// SMC의 CH0B(Charging Inhibit) 키에 0x02를 쓰면 충전 FET가 차단됨.
// 동시에 CH0C(Adapter Control) 키로 어댑터의 시스템 전력 공급도 차단.
// -> MacBook이 배터리 전원으로만 구동되면서 자연 방전됨.
//
// Apple Silicon 전력 경로:
//   [어댑터] -> [충전 IC] -> [시스템 레일] <- [배터리]
// 충전 IC의 FET를 차단하면 어댑터->배터리 경로가 끊기고,
// 시스템 레일의 전력 소스를 배터리로만 전환할 수 있음.

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
        try smc.setChargingInhibit(true)
        try smc.setAdapterDisconnect(true)
        try smc.writeChargeLimit(UInt8(settings.chargeLimit))
        isActive = true
    }

    func stop() throws {
        guard isActive else { return }
        try smc.setAdapterDisconnect(false)
        try smc.setChargingInhibit(false)
        try smc.writeChargeLimit(UInt8(settings.chargeLimit))
        isActive = false
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
