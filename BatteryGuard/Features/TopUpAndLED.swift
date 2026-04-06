// TopUpAndLED.swift
// Top Up 기능 + MagSafe LED 제어 (Apple Silicon)

import Foundation

// MARK: - Top Up
// 충전 억제를 해제하여 100%까지 충전 허용.
// 100% 도달 후 원래 Charge Limit에 따라 다시 억제.

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
        try smc.allowCharging()
        isActive = true
        print("[TopUp] activated → charging to 100%")
    }

    func deactivate() throws {
        // ChargeLimiter가 다음 틱에서 현재 잔량 기준으로 inhibit/allow 결정
        isActive = false
        print("[TopUp] deactivated → returning to limit \(settings.chargeLimit)%")
    }
}

// MARK: - MagSafe LED Controller
// ACLC SMC 키를 통해 MagSafe LED 상태를 제어.
// 0x00=off, 0x01=green, 0x02=orange, 0x03=auto, 0x04=error blink

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
