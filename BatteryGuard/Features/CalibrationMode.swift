// CalibrationMode.swift
// 배터리 캘리브레이션 기능
//
// 배터리 컨트롤러 IC는 쿨롱 카운팅으로 잔량을 추정함.
// 장기간 중간 SoC에만 머물면 추정 오차(gauge drift)가 누적됨.
// 풀 사이클을 수행하면 컨트롤러가 셀 전압의 상한/하한을 재학습.
//
// 캘리브레이션 사이클:
// Phase 1: 현재 -> 100% 충전
// Phase 2: 100% -> 10% 방전
// Phase 3: 10% -> 100% 재충전
// Phase 4: 100%에서 1시간 유지
// Phase 5: 원래 Charge Limit으로 복귀

import Foundation

final class CalibrationMode {
    private let smc: SMCKit
    private let monitor: BatteryMonitor
    private let settings: UserSettings
    private weak var controller: ChargeController?

    enum Phase: String {
        case idle = "대기"
        case charging1 = "1차 충전 (→100%)"
        case discharging = "방전 (→10%)"
        case charging2 = "2차 충전 (→100%)"
        case holding = "100% 유지 (1시간)"
        case restoring = "복원 중"
    }

    @Published private(set) var currentPhase: Phase = .idle
    private var holdStartTime: Date?
    private let holdDuration: TimeInterval = 3600

    private var originalChargeLimit: Int = 80
    private var originalHeatProtection: Bool = true

    init(smc: SMCKit, monitor: BatteryMonitor, settings: UserSettings, controller: ChargeController) {
        self.smc = smc
        self.monitor = monitor
        self.settings = settings
        self.controller = controller
    }

    func start() throws {
        originalChargeLimit = settings.chargeLimit
        originalHeatProtection = settings.heatProtectionEnabled
        settings.heatProtectionEnabled = false

        try smc.writeChargeLimit(100)
        try smc.setChargingInhibit(false)
        try smc.setAdapterDisconnect(false)
        currentPhase = .charging1
    }

    func runStep(batteryInfo: BatteryInfo) throws {
        switch currentPhase {
        case .idle:
            break

        case .charging1:
            if batteryInfo.currentCharge >= 100 {
                try smc.setChargingInhibit(true)
                try smc.setAdapterDisconnect(true)
                currentPhase = .discharging
            }

        case .discharging:
            if batteryInfo.currentCharge <= 10 {
                try smc.setAdapterDisconnect(false)
                try smc.setChargingInhibit(false)
                try smc.writeChargeLimit(100)
                currentPhase = .charging2
            }

        case .charging2:
            if batteryInfo.currentCharge >= 100 {
                holdStartTime = Date()
                currentPhase = .holding
            }

        case .holding:
            if let start = holdStartTime,
               Date().timeIntervalSince(start) >= holdDuration {
                currentPhase = .restoring
                try restore()
            }

        case .restoring:
            break
        }
    }

    private func restore() throws {
        try smc.writeChargeLimit(UInt8(originalChargeLimit))
        settings.chargeLimit = originalChargeLimit
        settings.heatProtectionEnabled = originalHeatProtection
        try smc.setChargingInhibit(false)
        try smc.setAdapterDisconnect(false)
        currentPhase = .idle
        controller?.isCalibrating = false
        monitor.allowSleep()
    }

    func cancel() throws {
        try restore()
    }

    var progress: Double {
        switch currentPhase {
        case .idle: return 0
        case .charging1: return 0.1
        case .discharging: return 0.3
        case .charging2: return 0.6
        case .holding:
            guard let start = holdStartTime else { return 0.8 }
            let elapsed = Date().timeIntervalSince(start)
            return 0.8 + 0.15 * min(elapsed / holdDuration, 1.0)
        case .restoring: return 0.95
        }
    }
}
