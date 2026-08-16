// ChargeController+Operations.swift
// User intent and owned Top Up/Discharge operation coordination.

import Foundation

@MainActor
extension ChargeController {
    // MARK: - User actions

    func setHeatProtectionEnabled(_ enabled: Bool) {
        guard enabled != settings.heatProtectionEnabled else { return }
        guard !enabled || !isBatteryControlDisabled else {
            commandError = "Heat Protection을 사용하려면 먼저 BatteryGuard 충전 제어를 켜세요."
            refreshDisplayedError()
            return
        }
        cancelSMCTemperatureSample(clearCache: true)
        settings.heatProtectionEnabled = enabled
        if enabled {
            if let info = monitor.batteryInfo {
                sampleSMCTemperature(force: true)
                evaluateHeatProtection(using: info)
            } else {
                sampleAfterHeatEnableGeneration = smcTemperatureSampleGeneration
                evaluateHeatProtectionWithoutBatteryInfo(temperature: nil)
            }
        } else if case .heatBlocked(let previous) = mode {
            restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
        } else if case .failed(let previous?, _, .heatProtection) = mode {
            restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
        } else if case .transitioning(.enteringHeat(let previous)) = mode {
            restoreAfterHeatProtection(
                previous: previous,
                requiresSafeTemperature: false,
                preemptCurrentOperation: true
            )
        } else if case .transitioning(.restoringHeat(let previous)) = mode {
            restoreAfterHeatProtection(
                previous: previous,
                requiresSafeTemperature: false,
                preemptCurrentOperation: true
            )
        }
    }

    func setLEDControlEnabled(_ enabled: Bool) {
        guard !enabled || !isBatteryControlDisabled else {
            commandError = "MagSafe LED를 제어하려면 먼저 BatteryGuard 충전 제어를 켜세요."
            refreshDisplayedError()
            return
        }
        guard enabled != settings.controlMagSafeLED else { return }
        settings.controlMagSafeLED = enabled
        ledIntent = nil
        updateLED()
    }

    func disableBatteryGuardControl() {
        let isRetryingReleasedControlDrift = isReleasedControlDrift
        guard isReady,
              activeOperationID == nil,
              !isReconcilingExternalState,
              (!hasExternalControlDrift || isRetryingReleasedControlDrift),
              (!isBatteryControlDisabled || isRetryingReleasedControlDrift) else { return }
        cancelPendingChargeLimit(reason: "BatteryGuard 제어 해제로 Charge Limit 변경이 취소됐습니다.")
        let lastLimit = effectiveChargeLimit
        let previous = mode.restorableMode
        let backend = self.backend
        do {
            try settings.beginBatteryControlRelease(lastLimit: lastLimit)
        } catch {
            commandError = "BatteryGuard 제어 해제를 안전하게 기록하지 못했습니다: \(error.localizedDescription)"
            refreshDisplayedError()
            return
        }
        _ = runBattery(
            operation: "release BatteryGuard control",
            transition: .releasingControl(previous: previous),
            failureDisposition: .manualIntervention,
            checkCancellationAfterWork: false,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                try await backend.releaseBatteryGuardControl()
                let status = try await backend.readControlStatus()
                guard status.isVerifiedControlReleased else {
                    throw BatteryError.commandFailed(
                        "release BatteryGuard control",
                        -1,
                        "released control was not strictly verified"
                    )
                }
                try await self.completeControlRelease(lastLimit: lastLimit)
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.mode = .controlDisabled(lastLimit: lastLimit)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.mode = .externalDrift(
                    expected: self.releasedControlExpectation(lastLimit: lastLimit),
                    observed: .unavailable(error.localizedDescription)
                )
            }
        )
    }

    func enableBatteryGuardControl() {
        guard isReady,
              activeOperationID == nil,
              !isReconcilingExternalState,
              case .system = settings.batteryControlOwnership,
              case .controlDisabled(let lastLimit) = mode else { return }
        let target = UserSettings.validatedChargeLimit(lastLimit)
        let backend = self.backend
        _ = runBattery(
            operation: "enable BatteryGuard control",
            transition: .applyingMaintain(target: target, previous: nil),
            checkCancellationAfterWork: false,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                try await backend.applyMaintain(level: target)
                let status = try await backend.readControlStatus()
                guard status.isVerifiedMaintain(level: target) else {
                    throw BatteryError.commandFailed(
                        "enable BatteryGuard control",
                        -1,
                        "verified Maintain was not established at \(target)%"
                    )
                }
                try self.settings.completeBatteryGuardEnable(lastLimit: target)
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.mode = .maintaining(limit: target)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.mode = .externalDrift(
                    expected: self.releasedControlExpectation(lastLimit: target),
                    observed: .unavailable(error.localizedDescription)
                )
            }
        )
    }

    func setChargeLimit(_ limit: Int) {
        guard isReady,
              activeOperationID == nil,
              !isReconcilingExternalState,
              !isTopUpActive,
              !isDischarging,
              !isHeatProtectionBlockingControls,
              case .maintaining = mode else {
            commandError = "현재 실행 중인 배터리 작업이 끝난 뒤 Charge Limit을 변경하세요."
            refreshDisplayedError()
            return
        }
        let target = UserSettings.validatedChargeLimit(limit)
        pendingChargeLimit = target
        chargeLimitDebounceWork?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.pendingChargeLimit == target else { return }
                self.chargeLimitDebounceWork = nil
                self.applyMaintain(limit: target, operation: "apply Charge Limit", updateStoredLimit: true) { [weak self] _ in
                    self?.pendingChargeLimit = nil
                }
            }
        }
        chargeLimitDebounceWork = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func startDischarge() {
        guard canStartExclusiveAction(named: "Discharge") else { return }
        guard let info = monitor.batteryInfo else {
            commandError = "배터리 상태를 확인할 수 없어 Discharge를 시작하지 않았습니다."
            refreshDisplayedError()
            return
        }
        let limit = effectiveChargeLimit
        guard info.currentCharge > limit else { return }
        guard monitor.preventSleep(reason: "BatteryGuard: Discharge in progress") else {
            commandError = "절전 방지 설정을 확보할 수 없어 Discharge를 시작하지 않았습니다."
            refreshDisplayedError()
            return
        }
        let backend = self.backend
        let didStart = runBattery(
            operation: "start Discharge",
            transition: .startingDischarge(target: limit, returnLimit: limit),
            work: {
                do {
                    try await backend.startDischarge(to: limit)
                } catch {
                    let operationError = error
                    try Task.checkCancellation()
                    do {
                        try await backend.applyMaintain(level: limit)
                    } catch {
                        throw ControlCompensationError(
                            operationError: operationError,
                            compensationError: error
                        )
                    }
                    throw operationError
                }
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.mode = .discharging(target: limit, returnLimit: limit)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                let compensationFailed = error is ControlCompensationError
                if !compensationFailed {
                    self.monitor.allowSleep()
                }
                self.mode = .failed(
                    previous: .maintaining(limit: limit),
                    message: error.localizedDescription,
                    disposition: compensationFailed
                        ? .manualIntervention
                        : .recoverPrevious
                )
            }
        )
        if !didStart {
            monitor.allowSleep()
        }
    }

    func stopDischarge() { stopDischarge(operation: "stop Discharge and resume maintain") }

    private func stopDischarge(operation: String) {
        guard case .discharging(_, let limit) = mode, activeOperationID == nil else { return }
        let backend = self.backend
        _ = runBattery(
            operation: operation,
            transition: .stoppingDischarge(returnLimit: limit),
            work: {
                try await backend.cancelLongRunningOperation()
                try Task.checkCancellation()
                try await backend.applyMaintain(level: limit)
            },
            onSuccess: { [weak self] in
                self?.monitor.allowSleep()
                self?.mode = .maintaining(limit: limit)
            }
        )
    }

    func startTopUp() {
        guard canStartExclusiveAction(named: "Top Up") else { return }
        guard let info = monitor.batteryInfo, info.isPluggedIn else {
            commandError = "전원 연결과 배터리 상태를 확인할 수 없어 Top Up을 시작하지 않았습니다."
            refreshDisplayedError()
            return
        }
        guard info.currentCharge < 100 else { return }
        let returnLimit = effectiveChargeLimit
        let backend = self.backend
        _ = runBattery(
            operation: "start Top Up",
            transition: .startingTopUp(returnLimit: returnLimit),
            work: {
                do {
                    try await backend.startTopUp(to: 100)
                } catch {
                    let operationError = error
                    try Task.checkCancellation()
                    do {
                        try await backend.applyMaintain(level: returnLimit)
                    } catch {
                        throw ControlCompensationError(
                            operationError: operationError,
                            compensationError: error
                        )
                    }
                    throw operationError
                }
            },
            onSuccess: { [weak self] in self?.mode = .toppingUp(returnLimit: returnLimit) },
            onFailure: { [weak self] error in
                self?.mode = .failed(
                    previous: .maintaining(limit: returnLimit),
                    message: error.localizedDescription,
                    disposition: error is ControlCompensationError
                        ? .manualIntervention
                        : .recoverPrevious
                )
            }
        )
    }

    func cancelTopUp() { stopTopUp(operation: "cancel Top Up and resume maintain") }

    private func stopTopUp(operation: String) {
        guard case .toppingUp(let limit) = mode, activeOperationID == nil else { return }
        let backend = self.backend
        _ = runBattery(
            operation: operation,
            transition: .stoppingTopUp(returnLimit: limit),
            work: {
                try await backend.cancelLongRunningOperation()
                try Task.checkCancellation()
                try await backend.applyMaintain(level: limit)
            },
            onSuccess: { [weak self] in self?.mode = .maintaining(limit: limit) }
        )
    }

    private func canStartExclusiveAction(named action: String) -> Bool {
        guard isReady,
              activeOperationID == nil,
              !isReconcilingExternalState,
              pendingChargeLimit == nil,
              !isHeatProtectionBlockingControls,
              case .maintaining = mode else {
            commandError = "Heat Protection 또는 다른 배터리 작업 중에는 \(action)를 시작할 수 없습니다."
            refreshDisplayedError()
            return false
        }
        return true
    }

    func applyMaintain(
        limit: Int,
        operation: String,
        updateStoredLimit: Bool,
        completion: (@MainActor (Result<Void, Error>) -> Void)? = nil
    ) {
        let validated = UserSettings.validatedChargeLimit(limit)
        let previous = mode.restorableMode
        let backend = self.backend
        _ = runBattery(
            operation: operation,
            transition: .applyingMaintain(target: validated, previous: previous),
            work: { try await backend.applyMaintain(level: validated) },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.mode = .maintaining(limit: validated)
                if updateStoredLimit { self.settings.chargeLimit = validated }
            },
            completion: completion
        )
    }

    func applyLongRunningProgressDecision(
        _ decision: LongRunningProgressDecision,
        batteryMeasurementAvailable: Bool
    ) {
        switch decision {
        case .none:
            break
        case .checkLiveness(let session):
            let fallbackMessage: String
            if !batteryMeasurementAvailable {
                fallbackMessage = "배터리 측정값이 없는 동안 장기 실행 프로세스가 종료되었습니다."
            } else {
                switch session {
                case .topUp:
                    fallbackMessage = "Top Up 프로세스가 목표 도달 전에 종료되었습니다."
                case .discharge:
                    fallbackMessage = "Discharge 프로세스가 목표 도달 전에 종료되었습니다."
                }
            }
            checkLongRunningOperation(session: session, fallbackMessage: fallbackMessage)
        case .finishAndRestoreMaintain(let session):
            switch session {
            case .topUp:
                stopTopUp(operation: "complete Top Up and resume maintain")
            case .discharge:
                stopDischarge(operation: "complete Discharge and resume maintain")
            }
        }
    }

    private func checkLongRunningOperation(
        session: LongRunningChargeSession,
        fallbackMessage: String
    ) {
        guard longRunningCheckTask == nil else { return }
        longRunningCheckGeneration &+= 1
        let checkID = longRunningCheckGeneration
        let operationGeneration = operationGeneration
        let backend = self.backend
        longRunningCheckTask = Task { [weak self] in
            let isActive = await backend.isLongRunningOperationActive()
            let result = isActive ? nil : await backend.longRunningOperationResult()
            guard let self else { return }
            guard self.longRunningCheckGeneration == checkID else { return }
            self.longRunningCheckTask = nil
            guard self.readiness == .ready,
                  !self.isShuttingDown,
                  self.operationGeneration == operationGeneration,
                  LongRunningChargePolicy.session(from: self.mode) == session,
                  !isActive else { return }
            let detail = result?.combinedOutput ?? ""
            let message = detail.isEmpty ? fallbackMessage : "\(fallbackMessage) \(detail)"
            await self.handleUnexpectedLongRunningExit(
                session: session,
                operationGeneration: operationGeneration,
                message: message
            )
        }
    }

    func handleUnexpectedLongRunningExit(
        session: LongRunningChargeSession,
        operationGeneration: UInt64,
        message: String
    ) async {
        guard readiness == .ready,
              !isShuttingDown,
              self.operationGeneration == operationGeneration,
              LongRunningChargePolicy.session(from: mode) == session,
              activeOperationID == nil else {
            return
        }

        let observed: ObservedChargeMode
        do {
            let status = try await backend.readControlStatus()
            guard readiness == .ready,
                  !isShuttingDown,
                  self.operationGeneration == operationGeneration,
                  LongRunningChargePolicy.session(from: mode) == session,
                  activeOperationID == nil else { return }
            observed = ChargeReconciliationPolicy.observedMode(from: status)
        } catch {
            guard readiness == .ready,
                  !isShuttingDown,
                  self.operationGeneration == operationGeneration,
                  LongRunningChargePolicy.session(from: mode) == session,
                  activeOperationID == nil else { return }
            observed = .unavailable(error.localizedDescription)
        }

        switch LongRunningChargePolicy.unexpectedExit(
            session: session,
            observed: observed
        ) {
        case .recoverMaintain(let session):
            recoverMaintainAfterUnexpectedExit(session: session, message: message)
        case .externalDrift(let expectation, let observed):
            mode = .externalDrift(expected: expectation, observed: observed)
            driftError = "외부 CLI 상태 감지: \(observed.userDescription). \(message)"
            refreshDisplayedError()
            await diagnostics.record(
                DiagnosticEvent(
                    category: .control,
                    operation: "long-running ownership lost",
                    outcome: .drifted,
                    message: message,
                    stateBefore: session.expectedMode.diagnosticLabel,
                    stateAfter: mode.diagnosticLabel
                )
            )
        }
    }

    func cancelLongRunningOperationCheck() {
        longRunningCheckGeneration &+= 1
        longRunningCheckTask?.cancel()
        longRunningCheckTask = nil
    }

    private func recoverMaintainAfterUnexpectedExit(
        session: LongRunningChargeSession,
        message: String
    ) {
        guard activeOperationID == nil else { return }
        let limit = session.returnLimit
        let backend = self.backend
        _ = runBattery(
            operation: "recover maintain after unexpected process exit",
            transition: .recoveringMaintain(limit: limit),
            work: { try await backend.applyMaintain(level: limit) },
            onSuccess: { [weak self] in
                guard let self else { return }
                if case .discharge = session {
                    self.monitor.allowSleep()
                }
                self.mode = .maintaining(limit: limit)
                self.commandError = message
            }
        )
    }

    func cancelPendingChargeLimit(reason: String) {
        guard pendingChargeLimit != nil else { return }
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
        commandError = reason
        refreshDisplayedError()
    }

}
