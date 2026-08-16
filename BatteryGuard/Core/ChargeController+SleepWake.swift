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
            willSleep: { [weak self] deadline in
                guard let self else { return true }
                return await self.prepareForSleep(deadlineUptimeNanoseconds: deadline)
            },
            didWake: { [weak self] in
                Task { @MainActor in await self?.reconcileAfterWake() }
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
        if let sleepPreparationTask {
            return await sleepPreparationTask.value
        }
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
            sleepChargingOffWasRequested = false
            return true
        case .rejectWithoutMutation:
            sleepChargingOffWasRequested = false
            return false
        case .verifyAlreadyProtected:
            if case .sleepProtected = mode {
                sleepChargingOffWasRequested = true
            } else {
                sleepChargingOffWasRequested = false
            }
            do {
                let status = try await backend.readControlStatus()
                guard status.isVerifiedChargingDisabled else {
                    throw BatteryError.commandFailed(
                        "verify sleep protection",
                        -1,
                        "charging was no longer strictly disabled"
                    )
                }
                return true
            } catch {
                sleepProtectionState = .unavailable(error.localizedDescription)
                commandError = "잠자기 충전 보호 검증 실패: \(error.localizedDescription)"
                refreshDisplayedError()
                return false
            }
        case .stopCharging(let previous):
            sleepChargingOffWasRequested = true
            sleepPreparationGeneration &+= 1
            let generation = sleepPreparationGeneration
            let task = Task { [weak self] in
                guard let self else { return false }
                return await self.stopChargingForSleep(
                    previous: previous,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
            }
            sleepPreparationTask = task
            let prepared = await task.value
            if sleepPreparationGeneration == generation {
                sleepPreparationTask = nil
            }
            return prepared
        }
    }

    private func stopChargingForSleep(
        previous: RestorableChargeMode,
        deadlineUptimeNanoseconds: UInt64?
    ) async -> Bool {
        activeOperationTask?.cancel()
        activeOperationTask = nil
        operationGeneration &+= 1
        let operationID = operationGeneration
        activeOperationID = operationID
        mode = .transitioning(.preparingForSleep(previous: previous))

        do {
            guard activeOperationID == operationID, !Task.isCancelled else { return false }
            let backendDeadline = deadlineUptimeNanoseconds.map { deadline in
                let acknowledgementReserve: UInt64 = 2_000_000_000
                return deadline > acknowledgementReserve ? deadline - acknowledgementReserve : 0
            }
            let status = try await backend.prepareForSystemSleep(
                deadlineUptimeNanoseconds: backendDeadline
            )
            guard activeOperationID == operationID else { return false }
            try Task.checkCancellation()
            guard status.isVerifiedChargingDisabled else {
                throw BatteryError.commandFailed(
                    "prepare for sleep",
                    -1,
                    "charging was not strictly verified disabled before sleep"
                )
            }
            guard activeOperationID == operationID else { return false }
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
            return true
        } catch {
            guard activeOperationID == operationID else { return false }
            activeOperationID = nil
            mode = .failed(
                previous: previous,
                message: error.localizedDescription,
                disposition: .manualIntervention
            )
            sleepProtectionState = .unavailable(error.localizedDescription)
            commandError = "잠자기 전 충전 중지 실패: \(error.localizedDescription)"
            refreshDisplayedError()
            recordDiagnostic(
                category: .lifecycle,
                operation: "prepare for sleep",
                error: error,
                stateAfter: mode.diagnosticLabel
            )
            return false
        }
    }

    func reconcileAfterWake() async {
        guard !isShuttingDown else { return }
        await finishSleepPreparationIfNeeded()
        sleepChargingOffWasRequested = false
        if let activeOperationTask {
            await activeOperationTask.value
        }
        guard !isShuttingDown else { return }
        cancelSMCTemperatureSample(clearCache: true)
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
