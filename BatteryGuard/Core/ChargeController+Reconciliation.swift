// ChargeController+Reconciliation.swift
// Read-only observation and explicit recovery from external CLI state.

import Foundation
import AppKit

@MainActor
extension ChargeController {
    // MARK: - External reconciliation

    func startExternalReconciliation() {
        stopExternalReconciliation()
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: reconciliationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reconcileExternalState(trigger: .periodic)
            }
        }
        reconciliationTimer?.tolerance = min(5, reconciliationInterval * 0.1)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.monitor.requestPresentationRefresh()
                await self.reconcileExternalState(trigger: .appActivation)
            }
        }
    }

    func stopExternalReconciliation() {
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        isReconcilingExternalState = false
    }

    func reconcileExternalState(trigger: ReconciliationTrigger = .manual) async {
        guard readiness == .ready,
              !isShuttingDown,
              activeOperationID == nil,
              pendingChargeLimit == nil,
              !isReconcilingExternalState,
              let expectation = reconciliationExpectation else {
            return
        }

        isReconcilingExternalState = true
        defer { isReconcilingExternalState = false }
        let stateBefore = mode.diagnosticLabel
        let generation = operationGeneration
        do {
            let snapshot = try await readReconciliationSnapshot(for: expectation)
            guard readiness == .ready,
                  !isShuttingDown,
                  activeOperationID == nil,
                  pendingChargeLimit == nil,
                  operationGeneration == generation,
                  reconciliationExpectation == expectation else {
                return
            }

            if ChargeReconciliationPolicy.status(snapshot, matches: expectation) {
                let recoveredFromFailure: Bool
                if case .failed = mode {
                    recoveredFromFailure = true
                } else {
                    recoveredFromFailure = false
                }
                let reconciledMode = expectation.reconciledMode
                if mode != reconciledMode {
                    if case .maintaining = expectation {
                        monitor.allowSleep()
                    }
                    mode = reconciledMode
                    if recoveredFromFailure { commandError = nil }
                    driftError = nil
                    refreshDisplayedError()
                    await diagnostics.record(
                        DiagnosticEvent(
                            category: .control,
                            operation: "\(trigger.rawValue) reconciliation restored",
                            outcome: .succeeded,
                            stateBefore: stateBefore,
                            stateAfter: mode.diagnosticLabel
                        )
                    )
                }
                return
            }

            let observed = ChargeReconciliationPolicy.observedMode(from: snapshot.status)
            let driftMode = ChargeMode.externalDrift(expected: expectation, observed: observed)
            guard mode != driftMode else { return }
            mode = driftMode
            driftError = "외부 CLI 변경 감지: \(observed.userDescription). BatteryGuard 제어를 잠갔습니다."
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operation: "\(trigger.rawValue) reconciliation",
                    outcome: .drifted,
                    message: snapshot.status.diagnosticDescription,
                    stateBefore: stateBefore,
                    stateAfter: mode.diagnosticLabel
                )
            )
        } catch {
            guard readiness == .ready,
                  !isShuttingDown,
                  activeOperationID == nil,
                  operationGeneration == generation,
                  reconciliationExpectation == expectation else {
                return
            }
            let observed = ObservedChargeMode.unavailable(error.localizedDescription)
            let driftMode = ChargeMode.externalDrift(expected: expectation, observed: observed)
            guard mode != driftMode else { return }
            mode = driftMode
            driftError = observed.userDescription
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operation: "\(trigger.rawValue) reconciliation",
                    outcome: .failed,
                    message: error.localizedDescription,
                    stateBefore: stateBefore,
                    stateAfter: mode.diagnosticLabel
                )
            )
        }
    }

    func refreshManualRecoveryStatus() async {
        guard case .failed(
            let previous,
            let message,
            .manualRecovery(let context)
        ) = mode,
              manualRecoveryRefreshAvailability.isAllowed else {
            await retryManualInterventionRecovery()
            return
        }

        let failedMode = mode
        let diagnosticOperationID = UUID()
        isReconcilingExternalState = true
        defer { isReconcilingExternalState = false }
        var observed = context.latestObservedState
        var statusDescription: String?
        do {
            let status = try await DiagnosticContext.$operationID.withValue(
                diagnosticOperationID
            ) {
                try await backend.readControlStatus()
            }
            guard mode == failedMode, !isShuttingDown else { return }
            statusDescription = status.diagnosticDescription
            observed = ChargeReconciliationPolicy.observedMode(from: status)
            if case .restoreMaintain(let limit) = context.target,
               status.isVerifiedMaintain(level: limit) {
                if settings.heatProtectionEnabled {
                    let temperature = await DiagnosticContext.$operationID.withValue(
                        diagnosticOperationID
                    ) {
                        await self.readFreshSafetyTemperature()
                    }
                    guard mode == failedMode, !isShuttingDown else { return }
                    guard temperature.permitsAutomaticCharging(
                        upTo: settings.heatProtectionThreshold
                    ) else {
                        throw BatteryError.unsupported(
                            "독립 온도 센서를 새로 확인할 수 없거나 안전 온도를 벗어났습니다."
                        )
                    }
                }
                monitor.allowSleep()
                mode = .maintaining(limit: limit)
                commandError = nil
                driftError = nil
                refreshDisplayedError()
                await diagnostics.record(
                    DiagnosticEvent(
                        category: .control,
                        operationID: diagnosticOperationID,
                        operation: "manual recovery status refreshed",
                        outcome: .succeeded,
                        message: statusDescription,
                        stateBefore: failedMode.diagnosticLabel,
                        stateAfter: mode.diagnosticLabel
                    )
                )
                return
            }
        } catch {
            guard mode == failedMode, !isShuttingDown else { return }
            let failureObservation = observed
                ?? .unavailable(error.localizedDescription)
            mode = .failed(
                previous: previous,
                message: message,
                disposition: .manualRecovery(
                    context.updating(observedState: failureObservation)
                )
            )
            commandError = "수동 복구 상태를 확인하지 못했습니다: \(error.localizedDescription)"
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operationID: diagnosticOperationID,
                    operation: "manual recovery status refreshed",
                    outcome: .failed,
                    message: error.localizedDescription,
                    stateBefore: failedMode.diagnosticLabel,
                    stateAfter: mode.diagnosticLabel
                )
            )
            return
        }

        guard mode == failedMode, !isShuttingDown else { return }
        mode = .failed(
            previous: previous,
            message: message,
            disposition: .manualRecovery(
                context.updating(
                    observedState: observed ?? .unavailable("실제 충전 상태를 확인할 수 없습니다.")
                )
            )
        )
        commandError = "현재 상태는 아직 명시적인 Maintain 복구가 필요합니다."
        refreshDisplayedError()
        await diagnostics.record(
            DiagnosticEvent(
                category: .control,
                operationID: diagnosticOperationID,
                operation: "manual recovery status refreshed",
                outcome: .drifted,
                message: statusDescription,
                stateBefore: failedMode.diagnosticLabel,
                stateAfter: mode.diagnosticLabel
            )
        )
    }

    func restoreMaintainFromManualRecovery() {
        guard explicitMaintainRecoveryAvailability.isAllowed,
              case .failed(let previous, _, .manualRecovery(let context)) = mode,
              case .restoreMaintain(let requestedLimit) = context.target else {
            if let denial = explicitMaintainRecoveryAvailability.denialReason {
                commandError = denial
                refreshDisplayedError()
            }
            return
        }

        let limit = UserSettings.validatedChargeLimit(requestedLimit)
        let backend = self.backend
        let monitor = self.monitor
        let settings = self.settings
        _ = runBattery(
            operation: "restore Maintain \(limit)%",
            transition: .recoveringMaintain(limit: limit),
            failureDisposition: .manualRecovery(context),
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                var latestObservedState = context.latestObservedState
                do {
                    guard settings.batteryControlEnabled else {
                        throw BatteryError.unsupported("BatteryGuard 충전 제어 소유권이 없습니다.")
                    }
                    guard let freshInfo = monitor.readBatteryInfo(), freshInfo.isPluggedIn else {
                        throw BatteryError.unsupported("전원 연결 상태를 새로 확인할 수 없습니다.")
                    }
                    monitor.batteryInfo = freshInfo
                    guard !(await backend.isLongRunningOperationActive()) else {
                        throw BatteryError.unsupported("BatteryGuard 장기 충전 작업이 아직 실행 중입니다.")
                    }
                    let preflightStatus = try await backend.readControlStatus()
                    latestObservedState = ChargeReconciliationPolicy.observedMode(
                        from: preflightStatus
                    )
                    guard preflightStatus.isDischarging == false else {
                        throw BatteryError.unsupported("방전 상태가 완전히 해제되지 않았습니다.")
                    }
                    guard preflightStatus.maintainWorker.isStopped
                            || preflightStatus.isVerifiedMaintain(level: limit) else {
                        throw BatteryError.unsupported("Maintain worker 상태가 안전한 복구 조건과 일치하지 않습니다.")
                    }
                    let preflightTemperature = await self.readFreshSafetyTemperature(
                        fallbackInfo: freshInfo
                    )
                    try Task.checkCancellation()
                    guard preflightTemperature.permitsAutomaticCharging(
                        upTo: settings.heatProtectionThreshold
                    ) else {
                        throw BatteryError.unsupported(
                            "독립 온도 센서 preflight가 완전하고 안전하지 않습니다."
                        )
                    }

                    if !preflightStatus.isVerifiedMaintain(level: limit) {
                        try await backend.applyMaintain(level: limit)
                    }
                    try Task.checkCancellation()
                    let verifiedStatus = try await backend.readControlStatus()
                    latestObservedState = ChargeReconciliationPolicy.observedMode(
                        from: verifiedStatus
                    )
                    guard verifiedStatus.isVerifiedMaintain(level: limit) else {
                        throw BatteryError.commandFailed(
                            "restore Maintain",
                            -1,
                            "complete Maintain \(limit)% tuple was not verified"
                        )
                    }

                    let postflightTemperature = await self.readFreshSafetyTemperature()
                    try Task.checkCancellation()
                    let postflightIsSafe = postflightTemperature.permitsAutomaticCharging(
                        upTo: settings.heatProtectionThreshold
                    ) && monitor.batteryInfo?.isPluggedIn == true
                    guard postflightIsSafe else {
                        try await backend.disableCharging()
                        let blockedStatus = try await backend.readControlStatus()
                        latestObservedState = ChargeReconciliationPolicy.observedMode(
                            from: blockedStatus
                        )
                        guard blockedStatus.isVerifiedChargingDisabled else {
                            throw BatteryError.commandFailed(
                                "restore Maintain safety rollback",
                                -1,
                                "unsafe postflight and charging-off rollback was not verified"
                            )
                        }
                        throw BatteryError.unsupported(
                            "복구 후 온도 또는 전원 postflight가 안전하지 않아 충전을 다시 중지했습니다."
                        )
                    }
                    let finalStatus = try await backend.readControlStatus()
                    latestObservedState = ChargeReconciliationPolicy.observedMode(
                        from: finalStatus
                    )
                    guard finalStatus.isVerifiedMaintain(level: limit) else {
                        throw BatteryError.commandFailed(
                            "restore Maintain final verification",
                            -1,
                            "complete Maintain \(limit)% tuple changed during postflight"
                        )
                    }
                } catch {
                    if error is CancellationError { throw error }
                    throw ManualMaintainRecoveryError(
                        underlying: error,
                        latestObservedState: latestObservedState
                    )
                }
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.monitor.allowSleep()
                self.mode = .maintaining(limit: limit)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                let updatedContext: ManualRecoveryContext
                if let recoveryError = error as? ManualMaintainRecoveryError,
                   let observed = recoveryError.latestObservedState {
                    updatedContext = context.updating(observedState: observed)
                } else {
                    updatedContext = context
                }
                self.mode = .failed(
                    previous: previous,
                    message: error.localizedDescription,
                    disposition: .manualRecovery(updatedContext)
                )
            }
        )
    }

    func retryManualInterventionRecovery() async {
        guard case .failed(let previous?, _, .manualIntervention) = mode,
              !isShuttingDown,
              activeOperationID == nil,
              pendingChargeLimit == nil,
              !isReconcilingExternalState else {
            return
        }

        let failedMode = mode
        let readinessBeforeRecovery = readiness
        let expectation = manualRecoveryExpectation(for: previous)
        let stateBefore = failedMode.diagnosticLabel
        isReconcilingExternalState = true
        readiness = .reconciling
        defer { isReconcilingExternalState = false }

        do {
            let snapshot = try await readReconciliationSnapshot(for: expectation)
            guard !isShuttingDown, mode == failedMode else { return }

            if ChargeReconciliationPolicy.status(snapshot, matches: expectation) {
                if settings.heatProtectionEnabled {
                    let temperature = await readFreshSafetyTemperature()
                    try Task.checkCancellation()
                    guard !isShuttingDown, mode == failedMode else { return }
                    guard temperature.permitsAutomaticCharging(
                        upTo: settings.heatProtectionThreshold
                    ) else {
                        throw BatteryError.unsupported(
                            "독립 온도 센서 전체를 새로 확인할 수 없거나 안전 온도를 벗어나 수동 복구를 승인하지 않았습니다."
                        )
                    }
                }
                if case .maintaining = expectation {
                    monitor.allowSleep()
                }
                mode = expectation.reconciledMode
                readiness = .ready
                commandError = nil
                driftError = nil
                refreshDisplayedError()
                await diagnostics.record(
                    DiagnosticEvent(
                        category: .control,
                        operation: "manual recovery verified",
                        outcome: .succeeded,
                        stateBefore: stateBefore,
                        stateAfter: mode.diagnosticLabel
                    )
                )
                return
            }

            let observed = ChargeReconciliationPolicy.observedMode(from: snapshot.status)
            mode = .externalDrift(expected: expectation, observed: observed)
            readiness = .ready
            commandError = nil
            driftError = "수동 복구 확인 결과: \(observed.userDescription). 기대 상태와 일치하지 않습니다."
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operation: "manual recovery verification",
                    outcome: .drifted,
                    message: snapshot.status.diagnosticDescription,
                    stateBefore: stateBefore,
                    stateAfter: mode.diagnosticLabel
                )
            )
        } catch {
            guard !isShuttingDown, mode == failedMode else { return }
            readiness = readinessBeforeRecovery
            commandError = "수동 복구 상태를 확인하지 못했습니다: \(error.localizedDescription)"
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operation: "manual recovery verification",
                    outcome: .failed,
                    message: error.localizedDescription,
                    stateBefore: stateBefore,
                    stateAfter: mode.diagnosticLabel
                )
            )
        }
    }

    func readReconciliationSnapshot(
        for expectation: ReconciledChargeExpectation
    ) async throws -> ChargeReconciliationSnapshot {
        let status = try await backend.readControlStatus()
        let ownedLongRunningOperation: OwnedLongRunningOperationObservation
        switch expectation {
        case .toppingUp, .discharging:
            ownedLongRunningOperation = await backend.isLongRunningOperationActive()
                ? .active
                : .inactive
        case .controlReleasing, .controlReleased:
            ownedLongRunningOperation = await backend.isLongRunningOperationActive()
                ? .active
                : .inactive
        case .maintaining, .chargingDisabled, .sleepProtected:
            ownedLongRunningOperation = .notRequired
        }
        return ChargeReconciliationSnapshot(
            status: status,
            ownedLongRunningOperation: ownedLongRunningOperation
        )
    }

    func manualRecoveryExpectation(
        for previous: RestorableChargeMode
    ) -> ReconciledChargeExpectation {
        // Explicit recovery always converges an uncertain Top Up/Discharge
        // state to its recorded safe Maintain limit instead of reviving the
        // interrupted long-running operation.
        .maintaining(limit: previous.maintainLimit)
    }

    var reconciliationExpectation: ReconciledChargeExpectation? {
        if settings.batteryControlReleasePending {
            return .controlReleasing(lastLimit: settings.batteryControlOwnership.lastLimit)
        }
        switch mode {
        case .controlDisabled(let lastLimit): return .controlReleased(lastLimit: lastLimit)
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .heatBlocked(let previous): return .chargingDisabled(previous: previous)
        case .sleepProtected(let previous, _): return .sleepProtected(previous: previous)
        case .externalDrift(let expected, _): return expected
        case .failed(let previous?, _, .heatProtection):
            return .chargingDisabled(previous: previous)
        case .failed(let previous?, _, .recoverPrevious):
            return ChargeReconciliationPolicy.expectation(from: previous)
        case .idle, .transitioning, .failed: return nil
        }
    }

}
