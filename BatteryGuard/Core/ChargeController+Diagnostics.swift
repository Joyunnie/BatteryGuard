// ChargeController+Diagnostics.swift
// MagSafe LED intent, diagnostics, and error presentation.

import Foundation
import OSLog

@MainActor
extension ChargeController {
    // MARK: - MagSafe LED

    func updateLED() {
        let nextIntent: MagSafeLEDIntent
        if isBatteryControlDisabled || !settings.controlMagSafeLED {
            nextIntent = .restore
        } else {
            switch currentState {
            case .charging, .topUp: nextIntent = .solid(.orange)
            case .chargingPaused: nextIntent = .solid(.green)
            case .discharging: nextIntent = .blink
            case .notConnected, .unknown: nextIntent = .restore
            }
        }
        guard nextIntent != ledIntent else { return }
        ledIntent = nextIntent
        ledGeneration &+= 1
        let generation = ledGeneration
        let magSafeLED = self.magSafeLED
        Task { [weak controller = self] in
            let succeeded = await magSafeLED.apply(nextIntent, generation: generation) { [weak controller] error in
                await controller?.recordLEDError(error)
            }
            await MainActor.run {
                guard let controller, succeeded, controller.ledGeneration == generation else { return }
                controller.ledError = nil
                controller.refreshDisplayedError()
            }
        }
    }

    func completeControlRelease(lastLimit: Int) async throws {
        cancelSMCTemperatureSample(clearCache: true)
        try settings.completeBatteryControlRelease(lastLimit: lastLimit)
        settings.heatProtectionEnabled = false
        settings.controlMagSafeLED = false
        monitor.allowSleep()
        ledIntent = .restore
        ledGeneration &+= 1
        do {
            try await magSafeLED.shutdown(generation: ledGeneration)
        } catch {
            recordLEDError(error)
        }
    }

    func releasedControlExpectation(lastLimit: Int) -> ReconciledChargeExpectation {
        settings.batteryControlReleasePending
            ? .controlReleasing(lastLimit: lastLimit)
            : .controlReleased(lastLimit: lastLimit)
    }

    private func recordLEDError(_ error: Error) {
        ledError = "MagSafe LED 제어 실패: \(error.localizedDescription)"
        logger.error("MagSafe LED failure: \(error.localizedDescription, privacy: .public)")
        recordDiagnostic(category: .control, operation: "MagSafe LED", error: error)
        refreshDisplayedError()
    }

    func setSensorError(_ message: String) {
        guard sensorError != message else { return }
        sensorError = message
        recordDiagnostic(category: .sensor, operation: "sensor validation", outcome: .failed, message: message)
    }

    func clearSensorError() {
        sensorError = nil
    }

    func recordDiagnostic(
        category: DiagnosticCategory,
        operationID: UUID? = DiagnosticContext.operationID,
        operation: String,
        outcome: DiagnosticOutcome? = nil,
        message: String? = nil,
        error: Error? = nil,
        stateBefore: String? = nil,
        stateAfter: String? = nil
    ) {
        let event = DiagnosticEvent(
            category: category,
            operationID: operationID,
            operation: operation,
            outcome: outcome ?? (error == nil ? .succeeded : .failed),
            message: message ?? error?.localizedDescription,
            stateBefore: stateBefore,
            stateAfter: stateAfter
        )
        diagnostics.submit(event)
    }

    func refreshDisplayedError() {
        issues = issueRegistry.orderedIssues
        lastError = issues.first?.message
    }

    func actionAvailability(
        alsoRequiresNoPendingLimit: Bool,
        conflicts: Bool
    ) -> ChargeActionAvailability {
        if !isReady { return .denied("초기화가 완료되지 않았습니다.") }
        if isCommandPending { return .denied("다른 배터리 작업이 진행 중입니다.") }
        if alsoRequiresNoPendingLimit && isChargeLimitPending {
            return .denied("Charge Limit 변경이 대기 중입니다.")
        }
        if isHeatProtectionBlockingControls { return .denied("Heat Protection이 충전 제어를 잠갔습니다.") }
        if isBatteryControlDisabled { return .denied("BatteryGuard 충전 제어가 꺼져 있습니다.") }
        if hasExternalControlDrift { return .denied("외부 충전 상태를 먼저 해결해야 합니다.") }
        if conflicts { return .denied("충돌하는 충전 작업이 실행 중입니다.") }
        return .allowed
    }
}
