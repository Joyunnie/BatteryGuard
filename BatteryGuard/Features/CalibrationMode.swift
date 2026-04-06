// CalibrationMode.swift
// 배터리 캘리브레이션 기능 (Apple Silicon)
//
// 캘리브레이션 사이클:
// Phase 1: 현재 -> 100% 충전 (allowCharging)
// Phase 2: 100% -> 10% 방전 (enableForceDischarge)
// Phase 3: 10% -> 100% 재충전 (allowCharging)
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

        // Phase 1: 100%까지 충전 허용
        try smc.allowCharging()
        try smc.disableForceDischarge()
        currentPhase = .charging1
        print("[Calibration] start → Phase 1: charge to 100%")
    }

    func runStep(batteryInfo: BatteryInfo) throws {
        switch currentPhase {
        case .idle:
            break

        case .charging1:
            if batteryInfo.currentCharge >= 100 {
                try smc.inhibitCharging()
                try smc.enableForceDischarge()
                currentPhase = .discharging
                print("[Calibration] Phase 2: discharge to 10%")
            }

        case .discharging:
            if batteryInfo.currentCharge <= 10 {
                try smc.disableForceDischarge()
                try smc.allowCharging()
                currentPhase = .charging2
                print("[Calibration] Phase 3: recharge to 100%")
            }

        case .charging2:
            if batteryInfo.currentCharge >= 100 {
                holdStartTime = Date()
                currentPhase = .holding
                print("[Calibration] Phase 4: hold at 100% for 1 hour")
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
        settings.chargeLimit = originalChargeLimit
        settings.heatProtectionEnabled = originalHeatProtection
        try smc.disableForceDischarge()
        try smc.allowCharging()
        currentPhase = .idle
        controller?.isCalibrating = false
        monitor.allowSleep()
        print("[Calibration] complete → restored limit \(originalChargeLimit)%")
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
