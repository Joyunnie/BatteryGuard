// TopUpAndLED.swift
// Top Up: battery charge 100 CLI로 대체 — ChargeController에서 직접 호출
// MagSafe LED: raw SMC ACLC 키 — async ChargeBackend를 통해 제어

import Foundation

// MARK: - MagSafe LED Controller
// ACLC SMC 키를 통해 MagSafe LED 상태를 제어.
// blink의 SMC 쓰기는 async backend를 통해 BatteryCommandRunner에 직렬화된다.

@MainActor
final class MagSafeLEDController {
    private let backend: ChargeBackend

    private var blinkTimer: Timer?
    private var blinkState = false

    init(backend: ChargeBackend) {
        self.backend = backend
    }

    func startBlink(onError: @escaping @MainActor @Sendable (Error) -> Void) {
        guard blinkTimer == nil else { return }
        blinkState = false

        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.blinkState.toggle()
                let state: MagSafeLEDState = self.blinkState ? .green : .orange
                do {
                    try await self.backend.setMagSafeLED(state)
                } catch {
                    onError(error)
                }
            }
        }
    }

    func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }
}
