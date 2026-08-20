// ChargeController+SleepWake.swift
// System sleep preparation and verified wake reconciliation.

import Foundation
import AppKit

@MainActor
extension ChargeController {
    // MARK: - Sleep / Wake

    func setupSleepWakeObservers() throws {
        guard runsSystemPowerObservation else { return }
        try systemPowerObserver.start(
            willSleep: { [weak self] request in
                guard let self else { return true }
                return await self.prepareForSleep(request: request)
            },
            didComplete: { [weak self] event in
                Task { @MainActor in
                    await self?.handleSystemSleepCompletion(event)
                }
            }
        )
        if let wakeFallbackObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeFallbackObserver)
            self.wakeFallbackObserver = nil
        }
        systemPowerObservationError = nil
    }

    func setupWakeFallbackObserver() {
        guard runsSystemPowerObservation, wakeFallbackObserver == nil else { return }
        wakeFallbackObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reconcileAfterWake() }
        }
    }

    @discardableResult
    func prepareForSleep(deadlineUptimeNanoseconds: UInt64? = nil) async -> Bool {
        let request = SystemSleepRequest(
            id: UUID(),
            generation: sleepPreparationGeneration &+ 1,
            kind: .forcedSystemSleep,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds ?? UInt64.max
        )
        return await prepareForSleep(request: request)
    }

    @discardableResult
    func prepareForSleep(request: SystemSleepRequest) async -> Bool {
        if activeControllerSleepRequest?.id == request.id,
           let sleepPreparationTask {
            return await sleepPreparationTask.value
        }
        sleepPreparationTask?.cancel()
        sleepPreparationTask = nil
        sleepPreparationGeneration &+= 1
        let controllerGeneration = sleepPreparationGeneration
        activeControllerSleepRequest = request
        cancelPendingChargeLimit(reason: "Sleep으로 대기 중인 Charge Limit 변경이 취소됐습니다.")
        cancelSMCTemperatureSample(clearCache: true)
        guard !isShuttingDown else { return false }

        let action = SleepChargingPolicy.preparationAction(
            strategy: settings.sleepChargingStrategy,
            ownsBatteryControl: settings.batteryControlEnabled,
            mode: mode,
            effectiveLimit: effectiveChargeLimit
        )
        switch action {
        case .allowWithoutMutation:
            recordSleepLifecycleDiagnostic(
                request: request,
                operation: "sleep preparation skipped",
                outcome: .succeeded
            )
            return true
        case .rejectWithoutMutation:
            recordSleepLifecycleDiagnostic(
                request: request,
                operation: "sleep preparation rejected",
                outcome: .failed
            )
            return false
        case .verifyAlreadyProtected:
            do {
                let status = try await backend.verifyChargingDisabledForSystemSleep(
                    deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds
                )
                guard sleepPreparationGeneration == controllerGeneration,
                      activeControllerSleepRequest?.id == request.id,
                      !Task.isCancelled else { return false }
                guard status.isVerifiedChargingDisabled else {
                    throw BatteryError.commandFailed(
                        "verify sleep protection",
                        -1,
                        "charging was no longer strictly disabled"
                    )
                }
                recordSleepLifecycleDiagnostic(
                    request: request,
                    operation: "sleep protection verified",
                    outcome: .succeeded
                )
                return true
            } catch {
                guard sleepPreparationGeneration == controllerGeneration,
                      activeControllerSleepRequest?.id == request.id else { return false }
                sleepProtectionState = .unavailable(error.localizedDescription)
                commandError = "잠자기 충전 보호 검증 실패: \(error.localizedDescription)"
                refreshDisplayedError()
                recordSleepLifecycleDiagnostic(
                    request: request,
                    operation: "sleep protection verification",
                    outcome: error is CancellationError ? .cancelled : .failed,
                    error: error
                )
                return false
            }
        case .stopCharging(let previous):
            let task = Task { [weak self] in
                guard let self else { return false }
                return await self.stopChargingForSleep(
                    previous: previous,
                    request: request,
                    controllerGeneration: controllerGeneration
                )
            }
            sleepPreparationTask = task
            let prepared = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if sleepPreparationGeneration == controllerGeneration {
                sleepPreparationTask = nil
            }
            return prepared
        }
    }

    private func stopChargingForSleep(
        previous: RestorableChargeMode,
        request: SystemSleepRequest,
        controllerGeneration: UInt64
    ) async -> Bool {
        activeOperationTask?.cancel()
        activeOperationTask = nil
        operationGeneration &+= 1
        let operationID = operationGeneration
        activeOperationID = operationID
        mode = .transitioning(.preparingForSleep(previous: previous))

        do {
            guard activeOperationID == operationID,
                  sleepPreparationGeneration == controllerGeneration,
                  activeControllerSleepRequest?.id == request.id,
                  !Task.isCancelled else { return false }
            let acknowledgementReserve: UInt64 = 2_000_000_000
            let backendDeadline = request.deadlineUptimeNanoseconds > acknowledgementReserve
                ? request.deadlineUptimeNanoseconds - acknowledgementReserve
                : 0
            let status = try await backend.prepareForSystemSleep(
                deadlineUptimeNanoseconds: backendDeadline
            )
            guard activeOperationID == operationID,
                  sleepPreparationGeneration == controllerGeneration,
                  activeControllerSleepRequest?.id == request.id else { return false }
            try Task.checkCancellation()
            guard status.isVerifiedChargingDisabled else {
                throw BatteryError.commandFailed(
                    "prepare for sleep",
                    -1,
                    "charging was not strictly verified disabled before sleep"
                )
            }
            guard activeOperationID == operationID,
                  sleepPreparationGeneration == controllerGeneration,
                  activeControllerSleepRequest?.id == request.id else { return false }
            if case .discharging = previous {
                monitor.allowSleep()
            }
            activeOperationID = nil
            let charge = monitor.batteryInfo?.currentCharge
            mode = .sleepProtected(previous: previous, charge: charge)
            sleepProtectionState = .pausedForSleep(charge: charge)
            commandError = nil
            refreshDisplayedError()
            updateLED()
            recordSleepLifecycleDiagnostic(
                request: request,
                operation: "prepare for sleep",
                outcome: .succeeded
            )
            return true
        } catch {
            guard activeOperationID == operationID,
                  sleepPreparationGeneration == controllerGeneration,
                  activeControllerSleepRequest?.id == request.id else { return false }
            activeOperationID = nil
            if error is CancellationError { return false }
            let observed = (error as? SleepStatusSettlementError)?
                .observations.last
                .map { ChargeReconciliationPolicy.observedMode(from: $0.status) }
            mode = .failed(
                previous: previous,
                message: error.localizedDescription,
                disposition: .manualRecovery(
                    ManualRecoveryContext(
                        origin: .systemSleep(request.kind),
                        target: .restoreMaintain(limit: previous.maintainLimit),
                        latestObservedState: observed
                    )
                )
            )
            sleepProtectionState = .unavailable(error.localizedDescription)
            commandError = "잠자기 전 충전 중지 실패: \(error.localizedDescription)"
            refreshDisplayedError()
            recordDiagnostic(
                category: .lifecycle,
                operation: "prepare for sleep",
                error: error,
                stateAfter: mode.diagnosticLabel,
                sleepSettlement: request.sleepSettlementDiagnostic
            )
            return false
        }
    }

    func reconcileAfterWake() async {
        guard !isShuttingDown else { return }
        await finishSleepPreparationIfNeeded()
        activeControllerSleepRequest = nil
        if let activeOperationTask {
            await activeOperationTask.value
        }
        guard !isShuttingDown else { return }
        cancelSMCTemperatureSample(clearCache: true)
        if case .failed(
            let previous,
            let message,
            .manualRecovery(let context)
        ) = mode {
            await refreshManualSleepFailureObservation(
                previous: previous,
                message: message,
                context: context
            )
            return
        }
        var shouldRestoreSleepProtection = false
        let sleepExpectation: ReconciledChargeExpectation?
        if case .externalDrift(.sleepProtected(let previous), _) = mode {
            sleepExpectation = .sleepProtected(previous: previous)
        } else if case .sleepProtected(let previous, _) = mode {
            sleepExpectation = .sleepProtected(previous: previous)
        } else {
            sleepExpectation = nil
        }
        if let sleepExpectation {
            await reconcileExternalDriftAfterWake(expectation: sleepExpectation)
            guard case .sleepProtected = mode else { return }
            shouldRestoreSleepProtection = true
        } else if case .externalDrift(let expectation, _) = mode {
            await reconcileExternalDriftAfterWake(expectation: expectation)
            return
        }
        if !shouldRestoreSleepProtection {
            let expectation = reconciliationExpectation
                ?? mode.restorableMode.map(ChargeReconciliationPolicy.expectation(from:))
            if let expectation {
                await reconcileExternalDriftAfterWake(expectation: expectation)
            }
            return
        }
        let prior = RestorableChargeMode.maintaining(
            limit: mode.restorableMode?.maintainLimit ?? effectiveChargeLimit
        )
        activeOperationTask?.cancel()
        activeOperationTask = nil
        operationGeneration &+= 1
        let reconciliationID = operationGeneration
        activeOperationID = reconciliationID
        readiness = .reconciling
        safetyTemperatureCache.clear()
        ledIntent = nil
        do {
            try await backend.requestCancellation()
            guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
            let freshInfo = monitor.readBatteryInfo()
            if let freshInfo {
                monitor.batteryInfo = freshInfo
            }
            if settings.heatProtectionEnabled {
                let temperature = await readFreshSafetyTemperature(fallbackInfo: freshInfo)
                guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
                guard temperature.permitsAutomaticCharging(upTo: settings.heatProtectionThreshold) else {
                    try await backend.disableCharging()
                    guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
                    mode = .heatBlocked(previous: prior)
                    sleepProtectionState = settings.sleepChargingStrategy == .disabled ? .inactive : .ready
                    readiness = .ready
                    driftError = nil
                    activeOperationID = nil
                    updateLED()
                    return
                }
            }
            let limit = prior.maintainLimit
            try await backend.applyMaintain(level: limit)
            guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
            mode = .maintaining(limit: limit)
            sleepProtectionState = settings.sleepChargingStrategy == .disabled ? .inactive : .ready
            readiness = .ready
            driftError = nil
            activeOperationID = nil
            updateLED()
        } catch {
            guard activeOperationID == reconciliationID else { return }
            activeOperationID = nil
            mode = .failed(
                previous: prior,
                message: error.localizedDescription,
                disposition: .manualIntervention
            )
            readiness = .failed(error.localizedDescription)
            commandError = "Wake reconciliation 실패: \(error.localizedDescription)"
            sleepProtectionState = .unavailable(error.localizedDescription)
            refreshDisplayedError()
        }
    }

    func finishSleepPreparationIfNeeded() async {
        guard let sleepPreparationTask else { return }
        let generation = sleepPreparationGeneration
        _ = await sleepPreparationTask.value
        if sleepPreparationGeneration == generation {
            self.sleepPreparationTask = nil
        }
    }

    func handleSystemSleepCompletion(_ event: SystemSleepCompletionEvent) async {
        guard !isShuttingDown else { return }
        let completedRequest = activeControllerSleepRequest
        sleepPreparationGeneration &+= 1
        sleepPreparationTask?.cancel()
        sleepPreparationTask = nil
        activeControllerSleepRequest = nil
        if let completedRequest {
            recordDiagnostic(
                category: .lifecycle,
                operation: "system sleep completion",
                outcome: .succeeded,
                sleepSettlement: completedRequest.sleepSettlementDiagnostic(
                    completionEvent: event
                )
            )
        }
        switch event {
        case .negotiationCancelled, .poweredOn:
            await reconcileAfterWake()
        }
    }

    private func refreshManualSleepFailureObservation(
        previous: RestorableChargeMode?,
        message: String,
        context: ManualRecoveryContext
    ) async {
        let failedMode = mode
        let observed: ObservedChargeMode
        do {
            let status = try await backend.readControlStatus()
            observed = ChargeReconciliationPolicy.observedMode(from: status)
        } catch {
            observed = .unavailable(error.localizedDescription)
        }
        guard !isShuttingDown, mode == failedMode else { return }
        mode = .failed(
            previous: previous,
            message: message,
            disposition: .manualRecovery(context.updating(observedState: observed))
        )
        refreshDisplayedError()
    }

    private func recordSleepLifecycleDiagnostic(
        request: SystemSleepRequest,
        operation: String,
        outcome: DiagnosticOutcome,
        error: Error? = nil
    ) {
        recordDiagnostic(
            category: .lifecycle,
            operation: operation,
            outcome: outcome,
            error: error,
            stateAfter: mode.diagnosticLabel,
            sleepSettlement: request.sleepSettlementDiagnostic
        )
    }

    private func reconcileExternalDriftAfterWake(
        expectation: ReconciledChargeExpectation
    ) async {
        let prior: RestorableChargeMode
        if case .sleepProtected(let previous) = expectation {
            // Wake never resumes an interrupted Top Up or Discharge implicitly.
            prior = .maintaining(limit: previous.maintainLimit)
        } else {
            prior = expectation.restorableMode
        }
        activeOperationTask?.cancel()
        activeOperationTask = nil
        operationGeneration &+= 1
        let reconciliationID = operationGeneration
        activeOperationID = reconciliationID
        readiness = .reconciling
        safetyTemperatureCache.clear()
        ledIntent = nil

        do {
            try await backend.requestCancellation()
            guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
            let snapshot = try await readReconciliationSnapshot(for: expectation)
            guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
            guard ChargeReconciliationPolicy.status(snapshot, matches: expectation) else {
                let observed = ChargeReconciliationPolicy.observedMode(from: snapshot.status)
                mode = .externalDrift(expected: expectation, observed: observed)
                driftError = "Wake 후 외부 CLI 변경 유지: \(observed.userDescription)"
                readiness = .ready
                activeOperationID = nil
                refreshDisplayedError()
                updateLED()
                return
            }
            let freshInfo = monitor.readBatteryInfo()
            if let freshInfo {
                monitor.batteryInfo = freshInfo
            }
            let shouldEvaluateHeatProtection: Bool
            if case .controlReleasing = expectation {
                shouldEvaluateHeatProtection = false
            } else if case .controlReleased = expectation {
                shouldEvaluateHeatProtection = false
            } else {
                shouldEvaluateHeatProtection = settings.heatProtectionEnabled
            }
            if shouldEvaluateHeatProtection {
                let temperature = await readFreshSafetyTemperature(fallbackInfo: freshInfo)
                guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
                guard temperature.permitsAutomaticCharging(upTo: settings.heatProtectionThreshold) else {
                    try await backend.disableCharging()
                    guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
                    mode = .heatBlocked(previous: prior)
                    readiness = .ready
                    driftError = nil
                    activeOperationID = nil
                    updateLED()
                    return
                }
            }

            if case .maintaining = expectation {
                monitor.allowSleep()
            }
            mode = expectation.reconciledMode
            driftError = nil
            readiness = .ready
            activeOperationID = nil
            refreshDisplayedError()
            updateLED()
        } catch {
            guard activeOperationID == reconciliationID else { return }
            activeOperationID = nil
            mode = .externalDrift(expected: expectation, observed: .unavailable(error.localizedDescription))
            readiness = .ready
            driftError = "Wake 후 실제 충전 상태를 확인할 수 없습니다: \(error.localizedDescription)"
            refreshDisplayedError()
        }
    }

}

private extension SystemSleepRequest {
    var sleepSettlementDiagnostic: SleepSettlementDiagnostic {
        sleepSettlementDiagnostic(completionEvent: nil)
    }

    func sleepSettlementDiagnostic(
        completionEvent: SystemSleepCompletionEvent?
    ) -> SleepSettlementDiagnostic {
        SleepSettlementDiagnostic(
            requestID: id,
            requestGeneration: generation,
            requestKind: kind,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            completionEvent: completionEvent
        )
    }
}
