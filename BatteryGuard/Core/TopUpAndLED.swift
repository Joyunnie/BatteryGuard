// TopUpAndLED.swift
// Top Up: battery charge 100 CLI로 대체 — ChargeController에서 직접 호출
// MagSafe LED: raw SMC ACLC 키 — ChargeController가 smcQueue를 통해 제어

import Foundation

// MARK: - MagSafe LED Controller
// ACLC SMC 키를 통해 MagSafe LED 상태를 제어.
// blink의 SMC 쓰기를 caller가 지정한 백그라운드 큐에서 실행 — 메인 스레드 블로킹 방지

final class MagSafeLEDController {
    private let smc: SMCKit
    private let settings: UserSettings

    private var blinkTimer: Timer?
    private var blinkState = false

    init(smc: SMCKit, settings: UserSettings) {
        self.smc = smc
        self.settings = settings
    }

    /// blink을 시작하되, SMC 쓰기는 지정된 큐에서 실행
    func startBlink(on queue: DispatchQueue) {
        guard blinkTimer == nil else { return }
        blinkState = false

        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkState.toggle()
            let state: MagSafeLEDState = self.blinkState ? .green : .orange
            queue.async {
                try? self.smc.setMagSafeLED(state)
            }
        }
    }

    func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    deinit {
        stopBlink()
    }
}
