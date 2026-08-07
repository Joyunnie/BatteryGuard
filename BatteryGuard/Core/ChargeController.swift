// ChargeController.swift
// Main-actor state machine for measurements, verified CLI state, and UI intent.

import Foundation
import AppKit
import OSLog

@MainActor
final class ChargeController: ObservableObject {
    static let shared = ChargeController(history: .shared, diagnostics: .shared)
    private static let defaultReconciliationInterval: TimeInterval = 60
    private static let minimumReconciliationInterval: TimeInterval = 1

    private struct HeatRestoreReblockedError: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "Heat Protection restore failed and charging was blocked again: \(underlying.localizedDescription)"
        }
    }

    private struct ControlCompensationError: LocalizedError {
        let operationError: Error
        let compensationError: Error

        var errorDescription: String? {
            "operation failed: \(operationError.localizedDescription); verified Maintain recovery failed: \(compensationError.localizedDescription)"
        }
    }

    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "ChargeControl")
    private let backend: ChargeBackend
    private let monitor: BatteryMonitor
    private let settings: UserSettings
    private let history: BatteryHistory?
    private let diagnostics: DiagnosticLog
    private let reconciliationInterval: TimeInterval
    private let now: @Sendable () -> Date

    @Published private(set) var mode: ChargeMode = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var pendingChargeLimit: Int?
    @Published private(set) var readiness: ChargeControllerReadiness
    @Published private(set) var isReconcilingExternalState = false

    var isReady: Bool { readiness == .ready }
    var isCommandPending: Bool {
        if isReconcilingExternalState { return true }
        if activeOperationID != nil { return true }
        if case .transitioning = mode { return true }
        return false
    }
    var isChargeLimitPending: Bool { pendingChargeLimit != nil }
    var isDischarging: Bool {
        if case .discharging = mode { return true }
        if case .externalDrift(_, .discharging) = mode { return true }
        return false
    }
    var isTopUpActive: Bool {
        if case .toppingUp = mode { return true }
        return false
    }
    var heatProtectionTriggered: Bool {
        if case .heatBlocked = mode { return true }
        return false
    }
    var isBatteryControlDisabled: Bool {
        guard settings.batteryControlEnabled else { return true }
        if case .controlDisabled = mode { return true }
        if case .externalDrift(.controlReleasing, _) = mode { return true }
        if case .externalDrift(.controlReleased, _) = mode { return true }
        return false
    }
    var isReleasedControlDrift: Bool {
        if case .externalDrift(.controlReleasing, _) = mode { return true }
        if case .externalDrift(.controlReleased, _) = mode { return true }
        return false
    }
    var effectiveChargeLimit: Int {
        if case .externalDrift(let expected, _) = mode { return expected.restorableMode.maintainLimit }
        if case .controlDisabled(let lastLimit) = mode { return lastLimit }
        return mode.restorableMode?.maintainLimit ?? UserSettings.validatedChargeLimit(settings.chargeLimit)
    }
    var displayedChargeLimit: Int { pendingChargeLimit ?? effectiveChargeLimit }
    var currentState: ChargeState {
        guard let info = monitor.batteryInfo else { return .unknown }
        let logicallyConnected = info.isPluggedIn || isDischarging || isTopUpActive
        guard logicallyConnected else { return .notConnected }

        switch mode {
        case .controlDisabled:
            return info.isCharging ? .charging : .chargingPaused
        case .toppingUp: return .topUp
        case .discharging: return .discharging
        case .heatBlocked: return .chargingPaused
        case .maintaining(let limit):
            return info.isCharging && info.currentCharge < limit ? .charging : .chargingPaused
        case .transitioning: return .chargingPaused
        case .externalDrift(_, let observed):
            switch observed {
            case .maintaining(let limit):
                return info.isCharging && info.currentCharge < limit ? .charging : .chargingPaused
            case .charging: return .charging
            case .discharging: return .discharging
            case .chargingDisabled: return .chargingPaused
            case .unavailable, .inconsistent: return .unknown
            }
        case .failed, .idle: return .unknown
        }
    }
    var hasExternalControlDrift: Bool {
        if case .externalDrift = mode { return true }
        return false
    }
    var externalDriftDescription: String? {
        guard case .externalDrift(let expected, let observed) = mode else { return nil }
        return "기대: \(expected.userDescription) · 실제: \(observed.userDescription)"
    }
    var externalDriftRecoveryDescription: String? {
        guard case .externalDrift(let expected, _) = mode else { return nil }
        if case .controlReleasing = expected {
            return "BatteryGuard 제어 해제가 아직 완료되지 않았습니다. 제어 해제를 다시 시도하세요."
        }
        if case .controlReleased = expected {
            return "BatteryGuard 제어를 계속 끄려면 제어 해제를 다시 시도하거나 외부 maintain/discharge를 중지하세요."
        }
        return "Terminal에서 실제 상태를 BatteryGuard 기대 상태(\(expected.userDescription))로 복원한 뒤 다시 확인하세요."
    }
    var isHeatProtectionBlockingControls: Bool {
        switch mode {
        case .heatBlocked:
            return true
        case .transitioning(let transition):
            if case .enteringHeat = transition { return true }
            if case .restoringHeat = transition { return true }
        case .failed(_, _, .heatProtection):
            return true
        default:
            break
        }

        guard settings.heatProtectionEnabled else { return false }
        guard let lastTemperature else { return true }
        return lastTemperature > settings.heatProtectionThreshold
    }

    private var commandError: String?
    private var sensorError: String?
    private var ledError: String?
    private var driftError: String?
    private var controlTimer: Timer?
    private var smcTemperatureTimer: Timer?
    private var reconciliationTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var chargeLimitDebounceWork: DispatchWorkItem?
    private var isShuttingDown = false
    private var backendAvailableForShutdown: Bool
    private var initializationHardwareMutationAttempted: Bool
    private var operationGeneration: UInt64 = 0
    private var activeOperationID: UInt64?
    private var activeOperationTask: Task<Void, Never>?
    private var longRunningCheckGeneration: UInt64 = 0
    private var longRunningCheckTask: Task<Void, Never>?
    private var safetyTemperatureCache = SafetyTemperatureCache()
    private var lastTemperature: Double?
    private var smcTemperatureSampleGeneration: UInt64 = 0
    private var smcTemperatureSampleTask: Task<Void, Never>?
    private var sampleAfterHeatEnableGeneration: UInt64?
    private var heatProtectionRetryAfter: Date?
    private var ledIntent: MagSafeLEDIntent?
    private var ledGeneration: UInt64 = 0
    private(set) var magSafeLED: MagSafeLEDController

    init(
        backend: ChargeBackend = SMCKit.shared,
        monitor: BatteryMonitor? = nil,
        settings: UserSettings? = nil,
        initialReadiness: ChargeControllerReadiness = .initializing,
        initialMode: ChargeMode? = nil,
        history: BatteryHistory? = nil,
        reconciliationInterval: TimeInterval = 60,
        diagnostics: DiagnosticLog = .disabled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let resolvedMonitor = monitor ?? BatteryMonitor.shared
        let resolvedSettings = settings ?? UserSettings.shared
        self.backend = backend
        self.monitor = resolvedMonitor
        self.settings = resolvedSettings
        self.history = history
        self.diagnostics = diagnostics
        self.now = now
        self.reconciliationInterval = reconciliationInterval.isFinite
            ? max(Self.minimumReconciliationInterval, reconciliationInterval)
            : Self.defaultReconciliationInterval
        self.readiness = initialReadiness
        self.backendAvailableForShutdown = initialReadiness == .ready
        self.initializationHardwareMutationAttempted = initialReadiness == .ready
        self.mode = initialMode ?? (initialReadiness == .ready
            ? .maintaining(limit: UserSettings.validatedChargeLimit(resolvedSettings.chargeLimit))
            : .idle)
        self.magSafeLED = MagSafeLEDController(backend: backend)
    }

    // MARK: - Lifecycle

    func initialize() async throws {
        guard readiness != .shuttingDown else { throw CancellationError() }
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
                    if let temperature, temperature <= settings.heatProtectionThreshold {
                        initializationHardwareMutationAttempted = true
                        try await backend.applyMaintain(level: desiredLimit)
                        mode = .maintaining(limit: desiredLimit)
                        settings.chargeLimit = desiredLimit
                    } else {
                        if temperature == nil {
                            setSensorError("온도를 읽을 수 없어 Heat Protection이 degraded 상태입니다.")
                        }
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
            startDisplayLoop()
            setupSleepWakeObservers()
            readiness = .ready
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
        controlTimer?.invalidate()
        controlTimer = nil
        smcTemperatureTimer?.invalidate()
        smcTemperatureTimer = nil
        monitor.stopMonitoring()
        removeSleepWakeObservers()
        stopExternalReconciliation()
    }

    func shutdown() async throws {
        guard !isShuttingDown else {
            throw BatteryError.unsupported("종료 정리가 이미 진행됐거나 실패했습니다.")
        }

        let initializationFailedBeforeHardwareMutation: Bool
        if case .failed = readiness {
            initializationFailedBeforeHardwareMutation = !initializationHardwareMutationAttempted
        } else {
            initializationFailedBeforeHardwareMutation = false
        }
        guard backendAvailableForShutdown, !initializationFailedBeforeHardwareMutation else {
            isShuttingDown = true
            readiness = .shuttingDown
            prepareLocalShutdown()
            finishLocalShutdown()
            return
        }

        if !settings.batteryControlReleasePending,
           case .externalDrift(let expectation, _) = mode {
            try await refreshExternalDriftBeforeShutdown(expectation: expectation)
        }

        let modeBeforeShutdown = mode
        let readinessBeforeShutdown = readiness
        let requestedLimit = effectiveChargeLimit
        let requestedPolicy: ChargeShutdownPolicy
        do {
            requestedPolicy = try ChargeShutdownPlanner.requestedPolicy(
                for: ChargeShutdownContext(
                    ownership: settings.batteryControlOwnership,
                    mode: modeBeforeShutdown,
                    effectiveLimit: requestedLimit
                )
            )
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
            throw BatteryError.unsupported(message)
        }

        isShuttingDown = true
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
                mode = .failed(
                    previous: modeBeforeShutdown.restorableMode ?? .maintaining(limit: requestedLimit),
                    message: error.localizedDescription,
                    disposition: .manualIntervention
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
        activeOperationTask?.cancel()
        activeOperationTask = nil
        activeOperationID = nil
        operationGeneration &+= 1
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
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
        controlTimer?.invalidate()
        controlTimer = nil
        smcTemperatureTimer?.invalidate()
        smcTemperatureTimer = nil
        monitor.stopMonitoring()
        removeSleepWakeObservers()
        stopExternalReconciliation()
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
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Serialized operations

    @discardableResult
    private func runBattery(
        operation: String,
        transition: ChargeTransition,
        preemptCurrentOperation: Bool = false,
        failureDisposition: ChargeFailureDisposition = .recoverPrevious,
        checkCancellationAfterWork: Bool = true,
        work: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: (@MainActor (Error) -> Void)? = nil,
        completion: (@MainActor (Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        guard !isShuttingDown else { return false }
        guard activeOperationID == nil || preemptCurrentOperation else {
            commandError = "다른 배터리 명령이 실행 중입니다. 잠시 후 다시 시도하세요."
            refreshDisplayedError()
            return false
        }
        if preemptCurrentOperation {
            activeOperationTask?.cancel()
        }
        cancelLongRunningOperationCheck()

        operationGeneration &+= 1
        let operationID = operationGeneration
        let diagnosticOperationID = UUID()
        let stateBefore = mode.diagnosticLabel
        activeOperationID = operationID
        mode = .transitioning(transition)
        let logger = self.logger

        let task = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await DiagnosticContext.$operationID.withValue(diagnosticOperationID) {
                    if preemptCurrentOperation { try await self?.backend.requestCancellation() }
                    try Task.checkCancellation()
                    try await work()
                    if checkCancellationAfterWork { try Task.checkCancellation() }
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            guard self.activeOperationID == operationID else {
                await self.diagnostics.record(
                    DiagnosticEvent(
                        category: .control,
                        operationID: diagnosticOperationID,
                        operation: operation,
                        outcome: .superseded,
                        message: result.failure?.localizedDescription,
                        stateBefore: stateBefore,
                        stateAfter: self.mode.diagnosticLabel
                    )
                )
                return
            }
            self.activeOperationID = nil
            self.activeOperationTask = nil
            switch result {
            case .success:
                self.commandError = nil
                self.driftError = nil
                onSuccess()
            case .failure(let error):
                self.commandError = "\(operation): \(error.localizedDescription)"
                logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if let onFailure {
                    onFailure(error)
                } else {
                    self.mode = .failed(
                        previous: transition.previousMode,
                        message: error.localizedDescription,
                        disposition: failureDisposition
                    )
                }
            }
            self.refreshDisplayedError()
            self.recordDiagnostic(
                category: .control,
                operationID: diagnosticOperationID,
                operation: operation,
                error: result.failure,
                stateBefore: stateBefore,
                stateAfter: self.mode.diagnosticLabel
            )
            completion?(result)
        }
        activeOperationTask = task
        return true
    }

    // MARK: - Monitoring

    private func startDisplayLoop() {
        controlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDisplayState() }
        }
    }

    private func startSMCTemperatureLoop() {
        smcTemperatureTimer?.invalidate()
        cancelSMCTemperatureSample(clearCache: false)
        smcTemperatureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSMCTemperature() }
        }
        sampleSMCTemperature()
    }

    private func sampleSMCTemperature() {
        guard readiness == .ready,
              !isShuttingDown,
              settings.heatProtectionEnabled,
              case .batteryGuard = settings.batteryControlOwnership,
              smcTemperatureSampleTask == nil else { return }
        smcTemperatureSampleGeneration &+= 1
        let generation = smcTemperatureSampleGeneration
        let backend = self.backend
        smcTemperatureSampleTask = Task { [weak self] in
            let result: Result<Double, Error>
            do {
                let rawValue = Double(try await backend.readBatteryTemperature())
                guard let temperature = BatteryMonitor.validatedTemperature(rawValue) else {
                    throw BatteryError.unsupported("SMC가 유효하지 않은 배터리 온도 \(rawValue)°C를 반환했습니다.")
                }
                result = .success(temperature)
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
            case .success(let temperature):
                self.safetyTemperatureCache.record(temperature, at: self.now())
                if self.monitor.batteryInfo == nil {
                    self.evaluateHeatProtectionWithoutBatteryInfo(temperature: temperature)
                }
            case .failure:
                self.safetyTemperatureCache.clear()
                if self.monitor.batteryInfo == nil {
                    self.evaluateHeatProtectionWithoutBatteryInfo(temperature: nil)
                }
            }
        }
    }

    private func cancelSMCTemperatureSample(clearCache: Bool) {
        smcTemperatureSampleGeneration &+= 1
        smcTemperatureSampleTask?.cancel()
        smcTemperatureSampleTask = nil
        sampleAfterHeatEnableGeneration = nil
        if clearCache {
            safetyTemperatureCache.clear()
            lastTemperature = nil
        }
    }

    private func updateDisplayState() {
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

    func processBatteryInfo(_ info: BatteryInfo) {
        let historyLimit: Int?
        if case .externalDrift(_, .maintaining(let limit)) = mode {
            historyLimit = limit
        } else if case .externalDrift = mode {
            historyLimit = nil
        } else {
            historyLimit = mode.restorableMode?.maintainLimit
        }
        if let limit = historyLimit {
            history?.record(chargePercent: info.currentCharge, chargeLimit: limit)
        }
        if settings.heatProtectionEnabled {
            evaluateHeatProtection(using: info)
        } else {
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

    private func measuredTemperature(using info: BatteryInfo) -> Double? {
        let recentSMC = recentSMCTemperature()
        return [recentSMC, info.temperature]
            .compactMap { $0.flatMap(BatteryMonitor.validatedTemperature) }
            .max()
    }

    private func readFreshSafetyTemperature(fallbackInfo: BatteryInfo? = nil) async -> Double? {
        var values: [Double] = []
        do {
            let rawValue = Double(try await backend.readBatteryTemperature())
            guard let value = BatteryMonitor.validatedTemperature(rawValue) else {
                throw BatteryError.unsupported("SMC가 유효하지 않은 배터리 온도 \(rawValue)°C를 반환했습니다.")
            }
            safetyTemperatureCache.record(value, at: now())
            values.append(value)
        } catch {
            safetyTemperatureCache.clear()
        }
        let freshInfo = monitor.readBatteryInfo() ?? fallbackInfo
        if let freshInfo {
            monitor.batteryInfo = freshInfo
            if let temperature = freshInfo.temperature.flatMap(BatteryMonitor.validatedTemperature) {
                values.append(temperature)
            }
        }
        let value = values.max()
        lastTemperature = value
        return value
    }

    // MARK: - Heat Protection

    private func evaluateHeatProtection(using info: BatteryInfo) {
        applyHeatProtectionEvaluation(
            temperature: measuredTemperature(using: info),
            measurementContext: .batteryInfoAvailable
        )
    }

    private func evaluateHeatProtectionWithoutBatteryInfo(temperature: Double?) {
        applyHeatProtectionEvaluation(
            temperature: temperature,
            measurementContext: .batteryInfoUnavailable
        )
    }

    private func applyHeatProtectionEvaluation(
        temperature: Double?,
        measurementContext: HeatMeasurementContext
    ) {
        let evaluation = HeatProtectionPolicy.evaluate(
            HeatProtectionInput(
                temperature: temperature,
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
        if evaluation.temperature == nil {
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
                try await backend.disableCharging()
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.heatProtectionRetryAfter = nil
                self.monitor.allowSleep()
                self.mode = .heatBlocked(previous: previous)
                if self.sampleAfterHeatEnableGeneration == self.smcTemperatureSampleGeneration {
                    self.sampleAfterHeatEnableGeneration = nil
                    self.sampleSMCTemperature()
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

    private func restoreAfterHeatProtection(previous: RestorableChargeMode, requiresSafeTemperature: Bool) {
        guard activeOperationID == nil else { return }
        let backend = self.backend
        _ = runBattery(
            operation: "restore after Heat Protection",
            transition: .restoringHeat(previous: previous),
            failureDisposition: .heatProtection,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    if requiresSafeTemperature {
                        let restoreThreshold = self.settings.heatProtectionThreshold
                        guard let preflight = await self.readFreshSafetyTemperature(), preflight <= restoreThreshold - 2 else {
                            throw BatteryError.commandFailed("Heat Protection restore", -1, "fresh temperature is unavailable or above the restore threshold")
                        }
                    }
                    switch previous {
                    case .maintaining(let limit): try await backend.applyMaintain(level: limit)
                    case .toppingUp: try await backend.startTopUp(to: 100)
                    case .discharging(let target, _): try await backend.startDischarge(to: target)
                    }
                    if requiresSafeTemperature {
                        let postflightThreshold = self.settings.heatProtectionThreshold
                        guard let postflight = await self.readFreshSafetyTemperature(), postflight <= postflightThreshold else {
                            throw BatteryError.commandFailed("Heat Protection restore", -1, "post-restore temperature is unavailable or unsafe")
                        }
                    }
                } catch {
                    let restoreError = error
                    do {
                        try await backend.cancelLongRunningOperation()
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
                if case .discharging = previous,
                   !self.monitor.preventSleep(reason: "BatteryGuard: restored Discharge") {
                    self.commandError = "Discharge는 복원됐지만 절전 방지 설정에 실패했습니다."
                }
            },
            onFailure: { [weak self] error in
                guard let self else { return }
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
    }

    private static func mode(from restorable: RestorableChargeMode) -> ChargeMode {
        switch restorable {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit): return .discharging(target: target, returnLimit: returnLimit)
        }
    }

    private func recentSMCTemperature(maxAge: TimeInterval = 15) -> Double? {
        safetyTemperatureCache.recentValue(at: now(), maxAge: maxAge)
    }

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
                sampleSMCTemperature()
                evaluateHeatProtection(using: info)
            } else {
                sampleAfterHeatEnableGeneration = smcTemperatureSampleGeneration
                evaluateHeatProtectionWithoutBatteryInfo(temperature: nil)
            }
        } else if case .heatBlocked(let previous) = mode {
            restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
        } else if case .failed(let previous?, _, .heatProtection) = mode {
            restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
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
        let backend = self.backend
        _ = runBattery(
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
                if !self.monitor.preventSleep(reason: "BatteryGuard: Discharge in progress") {
                    self.commandError = "Discharge는 시작했지만 절전 방지 설정에 실패했습니다."
                }
            },
            onFailure: { [weak self] error in
                self?.mode = .failed(
                    previous: .maintaining(limit: limit),
                    message: error.localizedDescription,
                    disposition: error is ControlCompensationError
                        ? .manualIntervention
                        : .recoverPrevious
                )
            }
        )
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
                try await backend.applyMaintain(level: limit)
            },
            onSuccess: { [weak self] in self?.mode = .maintaining(limit: limit) }
        )
    }

    func toggleCharging() {
        guard let info = monitor.batteryInfo else {
            commandError = "배터리 상태를 확인할 수 없습니다."
            refreshDisplayedError()
            return
        }
        setChargeLimit(currentState == .chargingPaused ? 100 : info.currentCharge)
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

    private func applyMaintain(
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

    private func applyLongRunningProgressDecision(
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

    private func handleUnexpectedLongRunningExit(
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

    private func cancelLongRunningOperationCheck() {
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

    private func cancelPendingChargeLimit(reason: String) {
        guard pendingChargeLimit != nil else { return }
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
        commandError = reason
        refreshDisplayedError()
    }

    // MARK: - External reconciliation

    private func startExternalReconciliation() {
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
                await self?.reconcileExternalState(trigger: .appActivation)
            }
        }
    }

    private func stopExternalReconciliation() {
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

    private func readReconciliationSnapshot(
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
        case .maintaining, .chargingDisabled:
            ownedLongRunningOperation = .notRequired
        }
        return ChargeReconciliationSnapshot(
            status: status,
            ownedLongRunningOperation: ownedLongRunningOperation
        )
    }

    private var reconciliationExpectation: ReconciledChargeExpectation? {
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
        case .externalDrift(let expected, _): return expected
        case .failed(let previous?, _, .heatProtection):
            return .chargingDisabled(previous: previous)
        case .failed(let previous?, _, .recoverPrevious):
            return ChargeReconciliationPolicy.expectation(from: previous)
        case .idle, .transitioning, .failed: return nil
        }
    }

    // MARK: - Sleep / Wake

    private func setupSleepWakeObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareForSleep() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reconcileAfterWake() }
        }
    }

    private func prepareForSleep() {
        cancelPendingChargeLimit(reason: "Sleep으로 대기 중인 Charge Limit 변경이 취소됐습니다.")
        cancelSMCTemperatureSample(clearCache: true)
    }

    func reconcileAfterWake() async {
        guard !isShuttingDown else { return }
        cancelSMCTemperatureSample(clearCache: true)
        if case .externalDrift(let expectation, _) = mode {
            await reconcileExternalDriftAfterWake(expectation: expectation)
            return
        }
        if case .controlDisabled(let lastLimit) = mode {
            await reconcileExternalDriftAfterWake(
                expectation: .controlReleased(lastLimit: lastLimit)
            )
            return
        }
        let prior = mode.restorableMode ?? .maintaining(limit: effectiveChargeLimit)
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
                guard let temperature, temperature <= settings.heatProtectionThreshold else {
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
            let limit = prior.maintainLimit
            try await backend.applyMaintain(level: limit)
            guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
            mode = .maintaining(limit: limit)
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
            refreshDisplayedError()
        }
    }

    private func reconcileExternalDriftAfterWake(
        expectation: ReconciledChargeExpectation
    ) async {
        let prior = expectation.restorableMode
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
                guard let temperature, temperature <= settings.heatProtectionThreshold else {
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

            let snapshot = try await readReconciliationSnapshot(for: expectation)
            guard activeOperationID == reconciliationID, !Task.isCancelled else { return }
            if ChargeReconciliationPolicy.status(snapshot, matches: expectation) {
                if case .maintaining = expectation {
                    monitor.allowSleep()
                }
                mode = expectation.reconciledMode
                driftError = nil
            } else {
                let observed = ChargeReconciliationPolicy.observedMode(from: snapshot.status)
                mode = .externalDrift(expected: expectation, observed: observed)
                driftError = "Wake 후 외부 CLI 변경 유지: \(observed.userDescription)"
            }
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

    // MARK: - MagSafe LED

    private func updateLED() {
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

    private func completeControlRelease(lastLimit: Int) async throws {
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

    private func releasedControlExpectation(lastLimit: Int) -> ReconciledChargeExpectation {
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

    private func setSensorError(_ message: String) {
        guard sensorError != message else { return }
        sensorError = message
        recordDiagnostic(category: .sensor, operation: "sensor validation", outcome: .failed, message: message)
    }

    private func clearSensorError() {
        sensorError = nil
    }

    private func recordDiagnostic(
        category: DiagnosticCategory,
        operationID: UUID? = DiagnosticContext.operationID,
        operation: String,
        outcome: DiagnosticOutcome? = nil,
        message: String? = nil,
        error: Error? = nil,
        stateBefore: String? = nil,
        stateAfter: String? = nil
    ) {
        let diagnostics = diagnostics
        let event = DiagnosticEvent(
            category: category,
            operationID: operationID,
            operation: operation,
            outcome: outcome ?? (error == nil ? .succeeded : .failed),
            message: message ?? error?.localizedDescription,
            stateBefore: stateBefore,
            stateAfter: stateAfter
        )
        Task { await diagnostics.record(event) }
    }

    private func refreshDisplayedError() {
        lastError = sensorError ?? driftError ?? commandError ?? ledError
    }
}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
