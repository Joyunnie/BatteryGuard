// ChargeController+HeatProtection.swift
// Independent temperature evaluation and Heat Protection transitions.

import Foundation

@MainActor
extension ChargeController {
    private func measuredTemperature(using info: BatteryInfo) -> Double? {
        let recentSMC = recentSMCTemperature()
        let ioKit = info.temperature.flatMap(BatteryMonitor.validatedTemperature)
        return publishSafetyTemperature(
            smc: recentSMC,
            ioKit: ioKit,
            failures: smcTemperatureFailure.map { [$0] } ?? []
        )
    }

    func readFreshSafetyTemperature(
        fallbackInfo: BatteryInfo? = nil
    ) async -> FreshSafetyTemperatureRead {
        var smc: Double?
        var failures: [String] = []
        do {
            let sample = try await backend.readBatteryTemperature()
            let rawValue = Double(sample.maximum)
            guard let value = BatteryMonitor.validatedTemperature(rawValue) else {
                throw BatteryError.unsupported("SMC가 유효하지 않은 배터리 온도 \(rawValue)°C를 반환했습니다.")
            }
            safetyTemperatureCache.record(value, at: now())
            let sampleFailures = sample.failures.map { "SMC: \($0)" }
            smcTemperatureFailure = sampleFailures.isEmpty
                ? nil
                : sampleFailures.joined(separator: "; ")
            failures.append(contentsOf: sampleFailures)
            smc = value
        } catch {
            safetyTemperatureCache.clear()
            let failure = "SMC: \(error.localizedDescription)"
            smcTemperatureFailure = failure
            failures.append(failure)
        }
        let freshInfo = monitor.readBatteryInfo() ?? fallbackInfo
        var ioKit: Double?
        if let freshInfo {
            monitor.batteryInfo = freshInfo
            ioKit = freshInfo.temperature.flatMap(BatteryMonitor.validatedTemperature)
            if ioKit == nil { failures.append("IOKit: 유효한 배터리 온도 없음") }
        } else {
            failures.append("IOKit: 배터리 정보 없음")
        }
        let value = publishSafetyTemperature(smc: smc, ioKit: ioKit, failures: failures)
        if failures.isEmpty {
            clearSensorError()
        } else {
            setSensorError("Heat Protection 센서 degraded: \(failures.joined(separator: "; "))")
        }
        refreshDisplayedError()
        lastTemperature = value
        return FreshSafetyTemperatureRead(maximum: value, failures: failures)
    }

    @discardableResult
    func publishSafetyTemperature(
        smc: Double?,
        ioKit: Double?,
        failures: [String] = []
    ) -> Double? {
        var readings: [(SafetyTemperatureSource, Double)] = []
        if let smc = smc.flatMap(BatteryMonitor.validatedTemperature) {
            readings.append((.smc, smc))
        }
        if let ioKit = ioKit.flatMap(BatteryMonitor.validatedTemperature) {
            readings.append((.ioKit, ioKit))
        }
        guard let maximum = readings.map(\.1).max() else {
            if safetyTemperatureSnapshot.value != nil {
                safetyTemperatureSnapshot = SafetyTemperatureSnapshot(
                    value: safetyTemperatureSnapshot.value,
                    sources: safetyTemperatureSnapshot.sources,
                    freshness: .stale,
                    failures: failures
                )
            } else {
                safetyTemperatureSnapshot = SafetyTemperatureSnapshot(
                    value: nil,
                    sources: [],
                    freshness: .unavailable,
                    failures: failures
                )
            }
            return nil
        }
        safetyTemperatureSnapshot = SafetyTemperatureSnapshot(
            value: maximum,
            sources: readings.filter { $0.1 == maximum }.map(\.0),
            freshness: .fresh,
            failures: failures
        )
        return maximum
    }

    // MARK: - Heat Protection

    func evaluateHeatProtection(using info: BatteryInfo) {
        applyHeatProtectionEvaluation(
            temperature: measuredTemperature(using: info),
            measurementContext: .batteryInfoAvailable,
            sensorFailures: safetyTemperatureSnapshot.failures
        )
    }

    func evaluateHeatProtectionWithoutBatteryInfo(temperature: Double?) {
        applyHeatProtectionEvaluation(
            temperature: temperature,
            measurementContext: .batteryInfoUnavailable,
            sensorFailures: safetyTemperatureSnapshot.failures
        )
    }

    func applyHeatProtectionEvaluation(
        temperature: Double?,
        measurementContext: HeatMeasurementContext,
        sensorFailures: [String]
    ) {
        let policyTemperature: Double?
        if case .heatBlocked = mode, !sensorFailures.isEmpty {
            // Never resume charging from a blocked state while an independent
            // temperature source is still degraded.
            policyTemperature = nil
        } else {
            policyTemperature = temperature
        }
        let evaluation = HeatProtectionPolicy.evaluate(
            HeatProtectionInput(
                temperature: policyTemperature,
                threshold: settings.heatProtectionThreshold,
                measurementContext: measurementContext,
                mode: mode,
                effectiveLimit: effectiveChargeLimit,
                ownership: settings.batteryControlOwnership,
                retryAfter: heatProtectionRetryAfter,
                now: now()
            )
        )
        lastTemperature = evaluation.temperature
        if !sensorFailures.isEmpty {
            setSensorError("Heat Protection 센서 degraded: \(sensorFailures.joined(separator: "; "))")
        } else if evaluation.temperature == nil {
            let message = measurementContext == .batteryInfoAvailable
                ? "온도를 읽을 수 없어 Heat Protection이 degraded 상태입니다."
                : "배터리 측정값과 SMC 온도를 읽을 수 없어 Heat Protection이 충전을 차단합니다."
            setSensorError(message)
        } else {
            clearSensorError()
        }
        refreshDisplayedError()

        switch evaluation.action {
        case .none:
            break
        case .enter(let previous):
            enterHeatProtection(previous: previous)
        case .restore(let previous):
            restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: true)
        }
    }

    private func enterHeatProtection(previous: RestorableChargeMode, preemptingCurrentOperation: Bool = true) {
        cancelPendingChargeLimit(reason: "Heat Protection이 Charge Limit 변경을 취소했습니다.")
        let backend = self.backend
        _ = runBattery(
            operation: "enable Heat Protection",
            transition: .enteringHeat(previous: previous),
            preemptCurrentOperation: preemptingCurrentOperation,
            failureDisposition: .heatProtection,
            work: {
                try await backend.cancelLongRunningOperation()
                try Task.checkCancellation()
                try await backend.disableCharging()
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.heatProtectionRetryAfter = nil
                self.monitor.allowSleep()
                self.mode = .heatBlocked(previous: previous)
                if self.sampleAfterHeatEnableGeneration == self.smcTemperatureSampleGeneration {
                    self.sampleAfterHeatEnableGeneration = nil
                    self.sampleSMCTemperature(force: true)
                }
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.sampleAfterHeatEnableGeneration = nil
                self.heatProtectionRetryAfter = self.now().addingTimeInterval(10)
                self.mode = .failed(
                    previous: previous,
                    message: error.localizedDescription,
                    disposition: .heatProtection
                )
            }
        )
    }

    func restoreAfterHeatProtection(
        previous: RestorableChargeMode,
        requiresSafeTemperature: Bool,
        preemptCurrentOperation: Bool = false
    ) {
        guard activeOperationID == nil || preemptCurrentOperation else { return }
        let restoringDischarge: Bool
        if case .discharging = previous {
            restoringDischarge = true
            guard monitor.preventSleep(reason: "BatteryGuard: restored Discharge") else {
                commandError = "절전 방지 설정을 확보할 수 없어 Discharge를 복원하지 않았습니다."
                refreshDisplayedError()
                return
            }
        } else {
            restoringDischarge = false
        }
        let backend = self.backend
        let didStart = runBattery(
            operation: "restore after Heat Protection",
            transition: .restoringHeat(previous: previous),
            preemptCurrentOperation: preemptCurrentOperation,
            failureDisposition: .heatProtection,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    if requiresSafeTemperature {
                        let restoreThreshold = self.settings.heatProtectionThreshold
                        let preflight = await self.readFreshSafetyTemperature()
                        try Task.checkCancellation()
                        guard preflight.permitsAutomaticCharging(upTo: restoreThreshold - 2) else {
                            throw BatteryError.commandFailed("Heat Protection restore", -1, "fresh temperature is unavailable or above the restore threshold")
                        }
                    }
                    try Task.checkCancellation()
                    switch previous {
                    case .maintaining(let limit): try await backend.applyMaintain(level: limit)
                    case .toppingUp: try await backend.startTopUp(to: 100)
                    case .discharging(let target, _): try await backend.startDischarge(to: target)
                    }
                    try Task.checkCancellation()
                    if requiresSafeTemperature {
                        let postflightThreshold = self.settings.heatProtectionThreshold
                        let postflight = await self.readFreshSafetyTemperature()
                        try Task.checkCancellation()
                        guard postflight.permitsAutomaticCharging(upTo: postflightThreshold) else {
                            throw BatteryError.commandFailed("Heat Protection restore", -1, "post-restore temperature is unavailable or unsafe")
                        }
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    let restoreError = error
                    do {
                        try Task.checkCancellation()
                        try await backend.cancelLongRunningOperation()
                        try Task.checkCancellation()
                        try await backend.disableCharging()
                        throw HeatRestoreReblockedError(underlying: restoreError)
                    } catch let reblocked as HeatRestoreReblockedError {
                        throw reblocked
                    } catch {
                        throw BatteryError.commandFailed(
                            "Heat Protection restore",
                            -1,
                            "restore failed: \(restoreError.localizedDescription); re-block failed: \(error.localizedDescription)"
                        )
                    }
                }
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.heatProtectionRetryAfter = nil
                self.mode = Self.mode(from: previous)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                if restoringDischarge, error is HeatRestoreReblockedError {
                    self.monitor.allowSleep()
                }
                if error is HeatRestoreReblockedError {
                    self.mode = .heatBlocked(previous: previous)
                } else {
                    self.mode = .failed(
                        previous: previous,
                        message: error.localizedDescription,
                        disposition: .heatProtection
                    )
                }
            }
        )
        if !didStart, restoringDischarge {
            monitor.allowSleep()
        }
    }

    static func mode(from restorable: RestorableChargeMode) -> ChargeMode {
        switch restorable {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit): return .discharging(target: target, returnLimit: returnLimit)
        }
    }

    func recentSMCTemperature(maxAge: TimeInterval = 15) -> Double? {
        safetyTemperatureCache.recentValue(at: now(), maxAge: maxAge)
    }

}
