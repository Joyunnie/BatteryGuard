// TopUpAndLED.swift
// Top Up 기능 + MagSafe LED 제어

import Foundation

// MARK: - Top Up
// BCLM을 일시적으로 100으로 설정하여 완충 허용.
// 100% 도달 후 원래 Charge Limit으로 자동 복귀.

final class TopUpFeature {
    private let smc: SMCKit
    private let monitor: BatteryMonitor
    private let settings: UserSettings

    private(set) var isActive = false

    init(smc: SMCKit, monitor: BatteryMonitor, settings: UserSettings) {
        self.smc = smc
        self.monitor = monitor
        self.settings = settings
    }

    func activate() throws {
        try smc.writeChargeLimit(100)
        try smc.setChargingInhibit(false)
        isActive = true
    }

    func deactivate() throws {
        try smc.writeChargeLimit(UInt8(settings.chargeLimit))
        isActive = false
    }
}

// MARK: - MagSafe LED Controller
// APTS SMC 키를 통해 MagSafe LED 상태를 제어.
// 충전 상태에 따라 초록/주황/점멸로 표시.

final class MagSafeLEDController {
    private let smc: SMCKit
    private let settings: UserSettings

    private var blinkTimer: Timer?
    private var blinkState = false

    init(smc: SMCKit, settings: UserSettings) {
        self.smc = smc
        self.settings = settings
    }

    func setGreen() throws {
        stopBlink()
        try smc.setMagSafeLED(.green)
    }

    func setOrange() throws {
        stopBlink()
        try smc.setMagSafeLED(.orange)
    }

    func setOff() throws {
        stopBlink()
        try smc.setMagSafeLED(.off)
    }

    func setAuto() throws {
        stopBlink()
        try smc.setMagSafeLED(.auto)
    }

    /// 주황/초록 교차 점멸 (방전 중 표시)
    func blinkOrangeGreen() throws {
        guard blinkTimer == nil else { return }
        blinkState = false

        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkState.toggle()
            try? self.smc.setMagSafeLED(self.blinkState ? .green : .orange)
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    deinit {
        stopBlink()
    }
}
