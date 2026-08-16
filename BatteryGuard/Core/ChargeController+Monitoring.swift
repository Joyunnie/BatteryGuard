// ChargeController+Monitoring.swift
// Notification-driven measurements, watchdogs, and history recording.

import Foundation
import Combine

@MainActor
extension ChargeController {
    // MARK: - Monitoring

    func startBatteryInfoObservation() {
        batteryInfoObservation?.cancel()
        batteryInfoObservation = monitor.$batteryInfo
            .map(ControlMeasurement.init)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.readiness == .ready,
                          !self.isShuttingDown else { return }
                    self.updateDisplayState()
                }
            }
    }

    func startSMCTemperatureLoop() {
        smcTemperatureTimer?.invalidate()
        cancelSMCTemperatureSample(clearCache: false)
        smcTemperatureTimer = Timer.scheduledTimer(
            withTimeInterval: smcTemperatureSamplingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.sampleSMCTemperature() }
        }
        smcTemperatureTimer?.tolerance = min(0.5, smcTemperatureSamplingInterval * 0.1)
        sampleSMCTemperature(force: true)
    }

    func sampleSMCTemperature(force: Bool = false) {
        guard readiness == .ready,
              !isShuttingDown,
              settings.heatProtectionEnabled,
              case .batteryGuard = settings.batteryControlOwnership,
              smcTemperatureSampleTask == nil else { return }
        let sampleStartedAt = now()
        if !force,
           let lastSMCTemperatureSampleStartedAt,
           sampleStartedAt.timeIntervalSince(lastSMCTemperatureSampleStartedAt)
            < smcTemperatureSamplingInterval { return }
        lastSMCTemperatureSampleStartedAt = sampleStartedAt
        smcTemperatureSampleGeneration &+= 1
        let generation = smcTemperatureSampleGeneration
        let backend = self.backend
        smcTemperatureSampleTask = Task { [weak self] in
            let result: Result<BatteryTemperatureSample, Error>
            do {
                let sample = try await backend.readBatteryTemperature()
                let rawValue = Double(sample.maximum)
                guard BatteryMonitor.validatedTemperature(rawValue) != nil else {
                    throw BatteryError.unsupported("SMC가 유효하지 않은 배터리 온도 \(rawValue)°C를 반환했습니다.")
                }
                result = .success(sample)
            }
            catch { result = .failure(error) }
            guard let self else { return }
            guard self.smcTemperatureSampleGeneration == generation else { return }
            self.smcTemperatureSampleTask = nil
            guard !Task.isCancelled,
                  self.readiness == .ready,
                  !self.isShuttingDown,
                  self.settings.heatProtectionEnabled,
                  case .batteryGuard = self.settings.batteryControlOwnership else { return }
            switch result {
            case .success(let sample):
                let temperature = Double(sample.maximum)
                let failures = sample.failures.map { "SMC: \($0)" }
                self.smcTemperatureFailure = failures.isEmpty
                    ? nil
                    : failures.joined(separator: "; ")
                self.safetyTemperatureCache.record(temperature, at: self.now())
                let measured = self.publishSafetyTemperature(
                    smc: temperature,
                    ioKit: self.monitor.batteryInfo?.temperature,
                    failures: failures
                )
                self.applyHeatProtectionEvaluation(
                    temperature: measured,
                    measurementContext: self.monitor.batteryInfo == nil
                        ? .batteryInfoUnavailable
                        : .batteryInfoAvailable,
                    sensorFailures: failures
                )
            case .failure(let error):
                self.safetyTemperatureCache.clear()
                let failure = "SMC: \(error.localizedDescription)"
                self.smcTemperatureFailure = failure
                let measured = self.publishSafetyTemperature(
                    smc: nil,
                    ioKit: self.monitor.batteryInfo?.temperature,
                    failures: [failure]
                )
                self.applyHeatProtectionEvaluation(
                    temperature: measured,
                    measurementContext: self.monitor.batteryInfo == nil
                        ? .batteryInfoUnavailable
                        : .batteryInfoAvailable,
                    sensorFailures: [failure]
                )
            }
        }
    }

    func cancelSMCTemperatureSample(clearCache: Bool) {
        smcTemperatureSampleGeneration &+= 1
        smcTemperatureSampleTask?.cancel()
        smcTemperatureSampleTask = nil
        sampleAfterHeatEnableGeneration = nil
        if clearCache {
            safetyTemperatureCache.clear()
            smcTemperatureFailure = nil
            lastTemperature = nil
        }
    }

    func updateDisplayState() {
        guard let info = monitor.batteryInfo else {
            setSensorError("배터리 상태를 읽을 수 없습니다.")
            applyLongRunningProgressDecision(
                LongRunningChargePolicy.progress(mode: mode, currentCharge: nil),
                batteryMeasurementAvailable: false
            )
            if settings.heatProtectionEnabled {
                evaluateHeatProtectionWithoutBatteryInfo(temperature: recentSMCTemperature())
            }
            refreshDisplayedError()
            return
        }
        processBatteryInfo(info)
    }

    func synchronizeLongRunningMonitoring() {
        guard readiness == .ready,
              !isShuttingDown,
              let session = LongRunningChargePolicy.session(from: mode) else {
            stopLongRunningMonitoring()
            return
        }
        if longRunningHeartbeatTimer == nil {
            let timer = Timer.scheduledTimer(
                withTimeInterval: longRunningHeartbeatInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.runLongRunningHeartbeat()
                }
            }
            timer.tolerance = min(5, longRunningHeartbeatInterval * 0.1)
            longRunningHeartbeatTimer = timer
        }
        guard longRunningExitObservationTask == nil else { return }
        let operationGeneration = operationGeneration
        let backend = self.backend
        longRunningExitObservationTask = Task { [weak self] in
            let result = await backend.waitForLongRunningOperationExit()
            guard let self, !Task.isCancelled else { return }
            guard self.readiness == .ready,
                  !self.isShuttingDown,
                  self.operationGeneration == operationGeneration,
                  LongRunningChargePolicy.session(from: self.mode) == session else { return }
            self.longRunningExitObservationTask = nil
            let decision = await self.settledLongRunningExitDecision(
                session: session,
                operationGeneration: operationGeneration,
                result: result
            )
            guard self.readiness == .ready,
                  !self.isShuttingDown,
                  self.operationGeneration == operationGeneration,
                  LongRunningChargePolicy.session(from: self.mode) == session else { return }
            if case .finishAndRestoreMaintain = decision {
                self.applyLongRunningProgressDecision(
                    decision,
                    batteryMeasurementAvailable: self.monitor.batteryInfo != nil
                )
                return
            }
            let fallbackMessage: String
            switch session {
            case .topUp:
                fallbackMessage = "Top Up 프로세스가 목표 도달 전에 종료되었습니다."
            case .discharge:
                fallbackMessage = "Discharge 프로세스가 목표 도달 전에 종료되었습니다."
            }
            let detail = result?.combinedOutput ?? ""
            await self.handleUnexpectedLongRunningExit(
                session: session,
                operationGeneration: operationGeneration,
                message: detail.isEmpty ? fallbackMessage : "\(fallbackMessage) \(detail)"
            )
        }
    }

    private func settledLongRunningExitDecision(
        session: LongRunningChargeSession,
        operationGeneration: UInt64,
        result: BatteryCommandResult?
    ) async -> LongRunningProgressDecision {
        monitor.refreshBatteryInfo()
        var decision = LongRunningChargePolicy.progress(
            mode: mode,
            currentCharge: monitor.batteryInfo?.currentCharge
        )
        guard result?.termination == .exited,
              result?.exitCode == 0,
              decision != .finishAndRestoreMaintain(session) else {
            return decision
        }

        for delay in Self.longRunningExitSettlementDelays {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return decision
            }
            guard readiness == .ready,
                  !isShuttingDown,
                  self.operationGeneration == operationGeneration,
                  LongRunningChargePolicy.session(from: mode) == session else {
                return decision
            }
            monitor.refreshBatteryInfo()
            decision = LongRunningChargePolicy.progress(
                mode: mode,
                currentCharge: monitor.batteryInfo?.currentCharge
            )
            if decision == .finishAndRestoreMaintain(session) { return decision }
        }
        return decision
    }

    private func runLongRunningHeartbeat() {
        guard readiness == .ready, !isShuttingDown else {
            stopLongRunningMonitoring()
            return
        }
        let charge = monitor.batteryInfo?.currentCharge
        applyLongRunningProgressDecision(
            LongRunningChargePolicy.progress(mode: mode, currentCharge: charge),
            batteryMeasurementAvailable: charge != nil
        )
    }

    func stopLongRunningMonitoring() {
        longRunningHeartbeatTimer?.invalidate()
        longRunningHeartbeatTimer = nil
        longRunningExitObservationTask?.cancel()
        longRunningExitObservationTask = nil
    }

    private func historyLimitForRecording() -> Int? {
        if case .externalDrift(_, .maintaining(let limit)) = mode {
            return limit
        }
        if case .externalDrift = mode { return nil }
        return mode.restorableMode?.maintainLimit
    }

    func recordHistoryAfterStableModeTransition(from previousMode: ChargeMode) {
        guard mode != previousMode,
              readiness == .ready,
              !isShuttingDown,
              let info = monitor.batteryInfo else { return }
        switch mode {
        case .maintaining, .toppingUp, .discharging, .heatBlocked, .sleepProtected:
            recordHistorySample(info)
        case .externalDrift(_, .maintaining):
            recordHistorySample(info)
        case .idle, .transitioning, .controlDisabled, .failed, .externalDrift:
            break
        }
    }

    private func recordHistorySample(_ info: BatteryInfo) {
        guard let history, let limit = historyLimitForRecording() else {
            stopHistoryHeartbeat()
            return
        }
        let didRecord = history.record(chargePercent: info.currentCharge, chargeLimit: limit)
        if didRecord || historyHeartbeatTimer == nil {
            scheduleHistoryHeartbeat()
        }
    }

    private func scheduleHistoryHeartbeat() {
        historyHeartbeatTimer?.invalidate()
        guard history != nil, historyLimitForRecording() != nil, !isShuttingDown else {
            historyHeartbeatTimer = nil
            return
        }
        historyHeartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: historyHeartbeatInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyHeartbeatTimer = nil
                if let info = self.monitor.batteryInfo {
                    self.recordHistorySample(info)
                } else {
                    self.scheduleHistoryHeartbeat()
                }
            }
        }
        historyHeartbeatTimer?.tolerance = min(30, historyHeartbeatInterval * 0.05)
    }

    func stopHistoryHeartbeat() {
        historyHeartbeatTimer?.invalidate()
        historyHeartbeatTimer = nil
    }

    func processBatteryInfo(_ info: BatteryInfo) {
        recordHistorySample(info)
        if settings.heatProtectionEnabled {
            evaluateHeatProtection(using: info)
        } else {
            publishSafetyTemperature(
                smc: recentSMCTemperature(),
                ioKit: info.temperature,
                failures: smcTemperatureFailure.map { [$0] } ?? []
            )
            clearSensorError()
            if case .heatBlocked(let previous) = mode {
                restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
            } else if case .failed(let previous?, _, .heatProtection) = mode {
                restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
            }
        }

        applyLongRunningProgressDecision(
            LongRunningChargePolicy.progress(
                mode: mode,
                currentCharge: info.currentCharge
            ),
            batteryMeasurementAvailable: true
        )
        updateLED()
    }

    func setSleepChargingStrategy(_ strategy: SleepChargingStrategy) {
        settings.sleepChargingStrategy = strategy
        if strategy == .disabled {
            sleepProtectionState = .inactive
        } else if let systemPowerObservationError {
            sleepProtectionState = .unavailable(systemPowerObservationError)
        } else {
            sleepProtectionState = .ready
        }
    }

}
