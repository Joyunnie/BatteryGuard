// ChargeController+Lifecycle.swift
// Initialization, verified shutdown, and local observer teardown.

import Foundation
import AppKit

@MainActor
extension ChargeController {
    // MARK: - Lifecycle

    func initialize() async throws {
        guard readiness != .shuttingDown else { throw CancellationError() }
        guard !initializationInProgress else {
            throw BatteryError.unsupported("초기화가 이미 진행 중입니다.")
        }
        initializationInProgress = true
        defer { finishInitializationLifecycle() }
        readiness = .initializing
        mode = .idle
        do {
            try settings.requireDurableBatteryControlOwnership()
            try await backend.open()
            backendAvailableForShutdown = true
            readiness = .reconciling
            let observedStatus = try await backend.readControlStatus()
            monitor.startMonitoring()

            let desiredLimit = UserSettings.validatedChargeLimit(settings.chargeLimit)
            readiness = .establishingControl
            switch settings.batteryControlOwnership {
            case .releasing(let persistedLimit):
                let lastLimit = UserSettings.validatedChargeLimit(persistedLimit)
                do {
                    initializationHardwareMutationAttempted = true
                    try await backend.releaseBatteryGuardControl()
                    let releasedStatus = try await backend.readControlStatus()
                    guard releasedStatus.isVerifiedControlReleased else {
                        throw BatteryError.commandFailed(
                            "resume BatteryGuard control release",
                            -1,
                            "released control was not strictly verified"
                        )
                    }
                    try await completeControlRelease(lastLimit: lastLimit)
                    mode = .controlDisabled(lastLimit: lastLimit)
                } catch {
                    mode = .externalDrift(
                        expected: .controlReleasing(lastLimit: lastLimit),
                        observed: .unavailable(error.localizedDescription)
                    )
                    driftError = "중단된 BatteryGuard 제어 해제를 완료하지 못했습니다. 다시 시도하세요: \(error.localizedDescription)"
                }
            case .system(let persistedLimit):
                let lastLimit = UserSettings.validatedChargeLimit(persistedLimit)
                try await completeControlRelease(lastLimit: lastLimit)
                if observedStatus.isCompatibleWithReleasedControl {
                    mode = .controlDisabled(lastLimit: lastLimit)
                } else {
                    mode = .externalDrift(
                        expected: .controlReleased(lastLimit: lastLimit),
                        observed: ChargeReconciliationPolicy.observedMode(from: observedStatus)
                    )
                    driftError = "BatteryGuard 제어는 꺼져 있지만 외부 충전 제어가 감지됐습니다."
                }
            case .batteryGuard:
                guard let info = monitor.batteryInfo else {
                    throw BatteryError.unsupported("배터리 상태를 확인할 수 없어 초기 충전 상태를 안전하게 설정하지 않았습니다.")
                }
                let observedLimit = observedStatus.maintainWorker.isRunning
                    ? observedStatus.maintainLevel.flatMap { UserSettings.chargeLimitRange.contains($0) ? $0 : nil }
                    : nil
                let previous: RestorableChargeMode = .maintaining(limit: observedLimit ?? desiredLimit)
                if settings.heatProtectionEnabled {
                    let temperature = await readFreshSafetyTemperature(fallbackInfo: info)
                    guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
                    if temperature.permitsAutomaticCharging(upTo: settings.heatProtectionThreshold) {
                        initializationHardwareMutationAttempted = true
                        try await backend.applyMaintain(level: desiredLimit)
                        mode = .maintaining(limit: desiredLimit)
                        settings.chargeLimit = desiredLimit
                    } else {
                        initializationHardwareMutationAttempted = true
                        try await backend.cancelLongRunningOperation()
                        try await backend.disableCharging()
                        mode = .heatBlocked(previous: previous)
                    }
                } else {
                    initializationHardwareMutationAttempted = true
                    try await backend.applyMaintain(level: desiredLimit)
                    mode = .maintaining(limit: desiredLimit)
                    settings.chargeLimit = desiredLimit
                }
            }

            guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
            startBatteryInfoObservation()
            readiness = .ready
            synchronizeLongRunningMonitoring()
            updateDisplayState()
            do {
                try setupSleepWakeObservers()
            } catch {
                systemPowerObservationError = error.localizedDescription
                setupWakeFallbackObserver()
                sleepProtectionState = settings.sleepChargingStrategy == .disabled
                    ? .inactive
                    : .unavailable(error.localizedDescription)
                recordDiagnostic(
                    category: .lifecycle,
                    operation: "register system sleep observer",
                    error: error,
                    stateAfter: readiness.diagnosticLabel
                )
            }
            startSMCTemperatureLoop()
            startExternalReconciliation()
            refreshDisplayedError()
        } catch {
            if !isShuttingDown, !Task.isCancelled {
                cleanupAfterFailedInitialization()
                mode = .failed(
                    previous: mode.restorableMode,
                    message: error.localizedDescription,
                    disposition: .manualIntervention
                )
                readiness = .failed(error.localizedDescription)
                recordDiagnostic(
                    category: .lifecycle,
                    operation: "initialize",
                    error: error,
                    stateAfter: readiness.diagnosticLabel
                )
            }
            throw error
        }
    }

    private func cleanupAfterFailedInitialization() {
        cancelSMCTemperatureSample(clearCache: true)
        batteryInfoObservation?.cancel()
        batteryInfoObservation = nil
        smcTemperatureTimer?.invalidate()
        smcTemperatureTimer = nil
        stopLongRunningMonitoring()
        stopHistoryHeartbeat()
        monitor.stopMonitoring()
        removeSleepWakeObservers()
        stopExternalReconciliation()
    }

    private func finishInitializationLifecycle() {
        initializationInProgress = false
        let waiters = initializationCompletionWaiters
        initializationCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForInitializationIfNeeded() async {
        guard initializationInProgress else { return }
        await withCheckedContinuation { continuation in
            initializationCompletionWaiters.append(continuation)
        }
    }

    func shutdown() async throws {
        await waitForInitializationIfNeeded()
        guard !isShuttingDown else {
            throw BatteryError.unsupported("종료 정리가 이미 진행됐거나 실패했습니다.")
        }
        // Claim lifecycle ownership before the first suspension point so wake
        // reconciliation and duplicate quit requests cannot race this plan.
        isShuttingDown = true
        await finishSleepPreparationIfNeeded()

        let initializationFailedBeforeHardwareMutation: Bool
        if case .failed = readiness {
            initializationFailedBeforeHardwareMutation = !initializationHardwareMutationAttempted
        } else {
            initializationFailedBeforeHardwareMutation = false
        }
        guard backendAvailableForShutdown, !initializationFailedBeforeHardwareMutation else {
            readiness = .shuttingDown
            prepareLocalShutdown()
            finishLocalShutdown()
            return
        }

        if !settings.batteryControlReleasePending,
           case .externalDrift(let expectation, _) = mode {
            do {
                try await refreshExternalDriftBeforeShutdown(expectation: expectation)
            } catch {
                isShuttingDown = false
                throw error
            }
        }

        let modeBeforeShutdown = mode
        let readinessBeforeShutdown = readiness
        let requestedLimit = effectiveChargeLimit
        let requestedPolicy: ChargeShutdownPolicy
        do {
            if systemPowerObserver.activeSleepRequest?.kind == .forcedSystemSleep,
               mode.requiresChargingDisabledForActiveSleepTransition {
                // A forced systemWillSleep request cannot be rejected. Keep the
                // already verified charging-off tuple while allowing it to finish.
                requestedPolicy = .keepChargingDisabled
            } else {
                requestedPolicy = try ChargeShutdownPlanner.requestedPolicy(
                    for: ChargeShutdownContext(
                        ownership: settings.batteryControlOwnership,
                        mode: modeBeforeShutdown,
                        effectiveLimit: requestedLimit
                    )
                )
            }
        } catch {
            let message = error.localizedDescription
            commandError = message
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .lifecycle,
                    operation: "shutdown rejected",
                    outcome: .failed,
                    message: message,
                    stateBefore: mode.diagnosticLabel
                )
            )
            isShuttingDown = false
            throw BatteryError.unsupported(message)
        }

        sleepProtectionState = settings.sleepChargingStrategy == .disabled ? .inactive : .ready

        readiness = .shuttingDown
        prepareLocalShutdown()
        ledGeneration &+= 1
        let shutdownLEDGeneration = ledGeneration

        do {
            try await performVerifiedBatteryShutdown(
                requestedPolicy: requestedPolicy,
                requestedLimit: requestedLimit
            )
        } catch {
            isShuttingDown = false
            if case .failed = readinessBeforeShutdown {
                readiness = readinessBeforeShutdown
            } else {
                readiness = .ready
            }
            if settings.expectsReleasedBatteryControl {
                let lastLimit = settings.batteryControlOwnership.lastLimit
                mode = .externalDrift(
                    expected: releasedControlExpectation(lastLimit: lastLimit),
                    observed: .unavailable(error.localizedDescription)
                )
            } else {
                let recoveryMode: RestorableChargeMode
                let failureDisposition: ChargeFailureDisposition
                switch requestedPolicy {
                case .keepChargingDisabled:
                    recoveryMode = modeBeforeShutdown.restorableMode
                        ?? .maintaining(limit: requestedLimit)
                    failureDisposition = .heatProtection
                case .restoreMaintain(let limit):
                    recoveryMode = .maintaining(limit: limit)
                    failureDisposition = .manualIntervention
                case .preserveMaintain, .preserveReleasedControl, .releaseControl:
                    recoveryMode = .maintaining(limit: requestedLimit)
                    failureDisposition = .manualIntervention
                }
                mode = .failed(
                    previous: recoveryMode,
                    message: error.localizedDescription,
                    disposition: failureDisposition
                )
            }
            commandError = "종료 안전 정리 실패: \(error.localizedDescription)"
            refreshDisplayedError()
            logger.error("Shutdown cleanup failed: \(error.localizedDescription, privacy: .public)")
            await diagnostics.record(
                DiagnosticEvent(
                    category: .lifecycle,
                    operation: "shutdown cleanup",
                    outcome: .failed,
                    message: error.localizedDescription
                )
            )
            throw error
        }

        monitor.allowSleep()
        do {
            try await magSafeLED.shutdown(generation: shutdownLEDGeneration)
            ledError = nil
            refreshDisplayedError()
        } catch {
            ledError = "MagSafe LED 자동 복원 실패: \(error.localizedDescription)"
            refreshDisplayedError()
            logger.error("MagSafe LED restore failed during shutdown: \(error.localizedDescription, privacy: .public)")
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operation: "shutdown LED restore",
                    outcome: .failed,
                    message: error.localizedDescription
                )
            )
        }
        finishLocalShutdown()
    }

    private func prepareLocalShutdown() {
        cancelSMCTemperatureSample(clearCache: true)
        cancelLongRunningOperationCheck()
        stopLongRunningMonitoring()
        stopHistoryHeartbeat()
        activeOperationTask?.cancel()
        activeOperationTask = nil
        activeOperationID = nil
        operationGeneration &+= 1
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
        sleepPreparationGeneration &+= 1
        sleepPreparationTask?.cancel()
        sleepPreparationTask = nil
        systemPowerObserver.resolvePendingSleepRequestsForShutdown()
    }

    private func performVerifiedBatteryShutdown(
        requestedPolicy: ChargeShutdownPolicy,
        requestedLimit: Int
    ) async throws {
        try await backend.requestCancellation()
        let freshStatus = try await backend.readControlStatus()
        let shutdownPolicy = try ChargeShutdownPlanner.verifiedPolicy(
            requested: requestedPolicy,
            status: freshStatus,
            restoreLimit: requestedLimit
        )
        switch shutdownPolicy {
        case .preserveMaintain:
            break
        case .preserveReleasedControl:
            try await completeControlRelease(lastLimit: requestedLimit)
        case .releaseControl:
            try await backend.releaseBatteryGuardControl()
            let status = try await backend.readControlStatus()
            guard status.isVerifiedControlReleased else {
                throw BatteryError.commandFailed(
                    "shutdown release control",
                    -1,
                    "BatteryGuard control release was not verified"
                )
            }
            try await completeControlRelease(lastLimit: requestedLimit)
        case .restoreMaintain(let limit):
            try await backend.applyMaintain(level: limit)
            let status = try await backend.readControlStatus()
            guard status.isVerifiedMaintain(level: limit) else {
                throw BatteryError.commandFailed("shutdown maintain restore", -1, "verified maintain worker was not restored at \(limit)%")
            }
        case .keepChargingDisabled:
            try await backend.cancelLongRunningOperation()
            try await backend.disableCharging()
            let status = try await backend.readControlStatus()
            guard status.isVerifiedChargingDisabled else {
                throw BatteryError.commandFailed("shutdown heat protection", -1, "charging was not fully verified disabled")
            }
        }
    }

    private func finishLocalShutdown() {
        cancelSMCTemperatureSample(clearCache: true)
        batteryInfoObservation?.cancel()
        batteryInfoObservation = nil
        smcTemperatureTimer?.invalidate()
        smcTemperatureTimer = nil
        stopLongRunningMonitoring()
        stopHistoryHeartbeat()
        monitor.stopMonitoring()
        removeSleepWakeObservers()
        stopExternalReconciliation()
        systemPowerObserver.stop()
    }

    private func refreshExternalDriftBeforeShutdown(
        expectation: ReconciledChargeExpectation
    ) async throws {
        isReconcilingExternalState = true
        defer { isReconcilingExternalState = false }

        let observed: ObservedChargeMode
        do {
            let snapshot = try await readReconciliationSnapshot(for: expectation)
            guard case .externalDrift(let currentExpectation, _) = mode,
                  currentExpectation == expectation else {
                throw BatteryError.unsupported("종료 전 상태 확인 중 제어 상태가 변경되었습니다. 다시 종료하세요.")
            }
            if ChargeReconciliationPolicy.status(snapshot, matches: expectation) {
                mode = expectation.reconciledMode
                driftError = nil
                refreshDisplayedError()
                return
            }
            observed = ChargeReconciliationPolicy.observedMode(from: snapshot.status)
        } catch {
            guard case .externalDrift(let currentExpectation, _) = mode,
                  currentExpectation == expectation else {
                throw error
            }
            observed = .unavailable(error.localizedDescription)
        }

        mode = .externalDrift(expected: expectation, observed: observed)
        driftError = "종료 전 실제 상태 확인 실패: \(observed.userDescription)"
        refreshDisplayedError()

        switch observed {
        case .maintaining, .chargingDisabled:
            return
        case .charging, .discharging, .unavailable, .inconsistent:
            let message = "외부 CLI 변경 상태를 먼저 해결해야 안전하게 종료할 수 있습니다: \(observed.userDescription)"
            commandError = message
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .lifecycle,
                    operation: "shutdown rejected",
                    outcome: .failed,
                    message: message,
                    stateBefore: mode.diagnosticLabel
                )
            )
            throw BatteryError.unsupported(message)
        }
    }

    private func removeSleepWakeObservers() {
        systemPowerObserver.stop()
        if let wakeFallbackObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeFallbackObserver)
            self.wakeFallbackObserver = nil
        }
    }

}
