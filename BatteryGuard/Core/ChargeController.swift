// ChargeController.swift
// Main-actor state machine for measurements, verified CLI state, and UI intent.

import Foundation
import AppKit
import OSLog

enum ChargeControllerReadiness: Equatable {
    case initializing
    case reconciling
    case establishingControl
    case ready
    case failed(String)
    case shuttingDown
}

enum RestorableChargeMode: Equatable {
    case maintaining(limit: Int)
    case toppingUp(returnLimit: Int)
    case discharging(target: Int, returnLimit: Int)

    var maintainLimit: Int {
        switch self {
        case .maintaining(let limit): return limit
        case .toppingUp(let returnLimit): return returnLimit
        case .discharging(_, let returnLimit): return returnLimit
        }
    }
}

enum ChargeTransition: Equatable {
    case applyingMaintain(target: Int, previous: RestorableChargeMode?)
    case startingTopUp(returnLimit: Int)
    case stoppingTopUp(returnLimit: Int)
    case startingDischarge(target: Int, returnLimit: Int)
    case stoppingDischarge(returnLimit: Int)
    case enteringHeat(previous: RestorableChargeMode)
    case restoringHeat(previous: RestorableChargeMode)
    case recoveringMaintain(limit: Int)

    var previousMode: RestorableChargeMode? {
        switch self {
        case .applyingMaintain(_, let previous): return previous
        case .startingTopUp(let limit), .stoppingTopUp(let limit), .recoveringMaintain(let limit):
            return .maintaining(limit: limit)
        case .startingDischarge(let target, let limit):
            return .discharging(target: target, returnLimit: limit)
        case .stoppingDischarge(let limit):
            return .maintaining(limit: limit)
        case .enteringHeat(let previous), .restoringHeat(let previous):
            return previous
        }
    }
}

enum ChargeMode: Equatable {
    case idle
    case maintaining(limit: Int)
    case toppingUp(returnLimit: Int)
    case discharging(target: Int, returnLimit: Int)
    case heatBlocked(previous: RestorableChargeMode)
    case transitioning(ChargeTransition)
    case failed(previous: RestorableChargeMode?, message: String, controlsBlocked: Bool)

    var restorableMode: RestorableChargeMode? {
        switch self {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .heatBlocked(let previous): return previous
        case .transitioning(let transition): return transition.previousMode
        case .failed(let previous, _, _): return previous
        case .idle: return nil
        }
    }
}

@MainActor
final class ChargeController: ObservableObject {
    static let shared = ChargeController()
    private static let shutdownCleanupTimeout: TimeInterval = 8

    private enum ShutdownControlPolicy: Sendable {
        case preserveMaintain
        case restoreMaintain(Int)
        case keepChargingDisabled
    }

    private struct HeatRestoreReblockedError: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "Heat Protection restore failed and charging was blocked again: \(underlying.localizedDescription)"
        }
    }

    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "ChargeControl")
    private let backend: ChargeBackend
    private let monitor: BatteryMonitor
    private let settings: UserSettings

    @Published private(set) var mode: ChargeMode = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var pendingChargeLimit: Int?
    @Published private(set) var readiness: ChargeControllerReadiness

    var isReady: Bool { readiness == .ready }
    var isCommandPending: Bool {
        if activeOperationID != nil { return true }
        if case .transitioning = mode { return true }
        return false
    }
    var isChargeLimitPending: Bool { pendingChargeLimit != nil }
    var isDischarging: Bool {
        if case .discharging = mode { return true }
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
    var effectiveChargeLimit: Int {
        mode.restorableMode?.maintainLimit ?? UserSettings.validatedChargeLimit(settings.chargeLimit)
    }
    var displayedChargeLimit: Int { pendingChargeLimit ?? effectiveChargeLimit }
    var currentState: ChargeState {
        guard let info = monitor.batteryInfo else { return .unknown }
        let logicallyConnected = info.isPluggedIn || isDischarging || isTopUpActive
        guard logicallyConnected else { return .notConnected }

        switch mode {
        case .toppingUp: return .topUp
        case .discharging: return .discharging
        case .heatBlocked: return .chargingPaused
        case .maintaining(let limit):
            return info.isCharging && info.currentCharge < limit ? .charging : .chargingPaused
        case .transitioning: return .chargingPaused
        case .failed, .idle: return .unknown
        }
    }
    var isHeatProtectionBlockingControls: Bool {
        switch mode {
        case .heatBlocked:
            return true
        case .transitioning(let transition):
            if case .enteringHeat = transition { return true }
            if case .restoringHeat = transition { return true }
        case .failed(_, _, let controlsBlocked):
            if controlsBlocked { return true }
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
    private var controlTimer: Timer?
    private var smcTemperatureTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var chargeLimitDebounceWork: DispatchWorkItem?
    private var isShuttingDown = false
    private var operationGeneration: UInt64 = 0
    private var activeOperationID: UInt64?
    private var isCheckingLongRunningOperation = false
    private var cachedSMCTemperature: Double?
    private var cachedSMCTemperatureAt: Date?
    private var lastTemperature: Double?
    private var isSamplingSMCTemperature = false
    private var heatProtectionRetryAfter: Date?
    private var ledIntent: MagSafeLEDIntent?
    private var ledGeneration: UInt64 = 0
    private(set) var magSafeLED: MagSafeLEDController

    init(
        backend: ChargeBackend = SMCKit.shared,
        monitor: BatteryMonitor? = nil,
        settings: UserSettings? = nil,
        initialReadiness: ChargeControllerReadiness = .initializing,
        initialMode: ChargeMode? = nil
    ) {
        let resolvedMonitor = monitor ?? BatteryMonitor.shared
        let resolvedSettings = settings ?? UserSettings.shared
        self.backend = backend
        self.monitor = resolvedMonitor
        self.settings = resolvedSettings
        self.readiness = initialReadiness
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
            try await backend.open()
            readiness = .reconciling
            let observedStatus = try await backend.readControlStatus()
            monitor.startMonitoring()
            guard let info = monitor.batteryInfo else {
                throw BatteryError.unsupported("배터리 상태를 확인할 수 없어 초기 충전 상태를 안전하게 설정하지 않았습니다.")
            }

            let desiredLimit = UserSettings.validatedChargeLimit(settings.chargeLimit)
            let observedLimit = observedStatus.maintainWorker.isRunning
                ? observedStatus.maintainLevel.flatMap { UserSettings.chargeLimitRange.contains($0) ? $0 : nil }
                : nil
            let previous: RestorableChargeMode = .maintaining(limit: observedLimit ?? desiredLimit)

            readiness = .establishingControl
            if settings.heatProtectionEnabled {
                let temperature = await readFreshSafetyTemperature(fallbackInfo: info)
                if let temperature, temperature <= settings.heatProtectionThreshold {
                    try await backend.applyMaintain(level: desiredLimit)
                    mode = .maintaining(limit: desiredLimit)
                    settings.chargeLimit = desiredLimit
                } else {
                    if temperature == nil {
                        sensorError = "온도를 읽을 수 없어 Heat Protection이 degraded 상태입니다."
                    }
                    try await backend.cancelLongRunningOperation()
                    try await backend.disableCharging()
                    mode = .heatBlocked(previous: previous)
                }
            } else {
                try await backend.applyMaintain(level: desiredLimit)
                mode = .maintaining(limit: desiredLimit)
                settings.chargeLimit = desiredLimit
            }

            guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
            startDisplayLoop()
            startSMCTemperatureLoop()
            setupSleepWakeObservers()
            readiness = .ready
            refreshDisplayedError()
        } catch {
            if !isShuttingDown, !Task.isCancelled {
                cleanupAfterFailedInitialization()
                mode = .failed(previous: mode.restorableMode, message: error.localizedDescription, controlsBlocked: true)
                readiness = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func cleanupAfterFailedInitialization() {
        controlTimer?.invalidate()
        controlTimer = nil
        smcTemperatureTimer?.invalidate()
        smcTemperatureTimer = nil
        monitor.stopMonitoring()
        removeSleepWakeObservers()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        let shutdownPolicy: ShutdownControlPolicy
        switch mode {
        case .toppingUp(let limit), .discharging(_, let limit):
            shutdownPolicy = .restoreMaintain(limit)
        case .transitioning(let transition):
            switch transition {
            case .enteringHeat, .restoringHeat:
                shutdownPolicy = .keepChargingDisabled
            default:
                shutdownPolicy = .restoreMaintain(transition.previousMode?.maintainLimit ?? effectiveChargeLimit)
            }
        case .heatBlocked, .failed(_, _, true):
            shutdownPolicy = .keepChargingDisabled
        default:
            shutdownPolicy = .preserveMaintain
        }

        readiness = .shuttingDown
        controlTimer?.invalidate()
        smcTemperatureTimer?.invalidate()
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
        monitor.stopMonitoring()
        monitor.allowSleep()
        ledGeneration &+= 1
        let shutdownLEDGeneration = ledGeneration
        removeSleepWakeObservers()

        let backend = self.backend
        let magSafeLED = self.magSafeLED
        let logger = self.logger
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await backend.requestCancellation()
                switch shutdownPolicy {
                case .preserveMaintain:
                    break
                case .restoreMaintain(let limit):
                    try await backend.applyMaintain(level: limit)
                    let status = try await backend.readControlStatus()
                    guard status.maintainLevel == limit,
                          status.maintainWorker.isRunning,
                          status.isDischarging != true else {
                        throw BatteryError.commandFailed("shutdown maintain restore", -1, "verified maintain worker was not restored at \(limit)%")
                    }
                case .keepChargingDisabled:
                    try await backend.disableCharging()
                    let status = try await backend.readControlStatus()
                    guard status.charging == .disabled else {
                        throw BatteryError.commandFailed("shutdown heat protection", -1, "charging was not verified disabled")
                    }
                }
                try await magSafeLED.shutdown(generation: shutdownLEDGeneration)
            } catch {
                logger.error("Shutdown cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + Self.shutdownCleanupTimeout) == .timedOut {
            logger.error("Shutdown cleanup timed out")
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
        controlsBlockedOnFailure: Bool = false,
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

        operationGeneration &+= 1
        let operationID = operationGeneration
        activeOperationID = operationID
        mode = .transitioning(transition)
        let logger = self.logger

        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                if preemptCurrentOperation { try await self?.backend.requestCancellation() }
                try Task.checkCancellation()
                try await work()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            guard let self, self.activeOperationID == operationID else { return }
            self.activeOperationID = nil
            switch result {
            case .success:
                self.commandError = nil
                onSuccess()
            case .failure(let error):
                self.commandError = "\(operation): \(error.localizedDescription)"
                logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if let onFailure {
                    onFailure(error)
                } else {
                    self.mode = .failed(previous: transition.previousMode, message: error.localizedDescription, controlsBlocked: controlsBlockedOnFailure)
                }
            }
            self.refreshDisplayedError()
            completion?(result)
        }
        return true
    }

    // MARK: - Monitoring

    private func startDisplayLoop() {
        controlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDisplayState() }
        }
    }

    private func startSMCTemperatureLoop() {
        smcTemperatureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSMCTemperature() }
        }
        sampleSMCTemperature()
    }

    private func sampleSMCTemperature() {
        guard settings.heatProtectionEnabled, !isSamplingSMCTemperature else { return }
        isSamplingSMCTemperature = true
        let backend = self.backend
        Task { [weak self] in
            let result: Result<Double, Error>
            do { result = .success(Double(try await backend.readBatteryTemperature())) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.isSamplingSMCTemperature = false
            switch result {
            case .success(let temperature):
                self.cachedSMCTemperature = temperature
                self.cachedSMCTemperatureAt = Date()
            case .failure:
                self.cachedSMCTemperature = nil
                self.cachedSMCTemperatureAt = nil
            }
        }
    }

    private func updateDisplayState() {
        guard let info = monitor.batteryInfo else {
            sensorError = "배터리 상태를 읽을 수 없습니다."
            refreshDisplayedError()
            return
        }
        processBatteryInfo(info)
    }

    func processBatteryInfo(_ info: BatteryInfo) {
        if settings.heatProtectionEnabled {
            evaluateHeatProtection(using: info)
        } else {
            sensorError = nil
            if case .heatBlocked(let previous) = mode {
                restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
            } else if case .failed(let previous?, _, true) = mode {
                restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: false)
            }
        }

        switch mode {
        case .toppingUp:
            if info.currentCharge >= 100 {
                stopTopUp(operation: "complete Top Up and resume maintain")
            } else {
                checkLongRunningOperation(expectedMode: mode, fallbackMessage: "Top Up 프로세스가 목표 도달 전에 종료되었습니다.")
            }
        case .discharging(let target, _):
            if info.currentCharge <= target {
                stopDischarge(operation: "complete Discharge and resume maintain")
            } else {
                checkLongRunningOperation(expectedMode: mode, fallbackMessage: "Discharge 프로세스가 목표 도달 전에 종료되었습니다.")
            }
        default:
            break
        }
        updateLED()
    }

    private func measuredTemperature(using info: BatteryInfo) -> Double? {
        let recentSMC: Double?
        if let cachedSMCTemperature,
           let cachedSMCTemperatureAt,
           Date().timeIntervalSince(cachedSMCTemperatureAt) <= 15 {
            recentSMC = cachedSMCTemperature
        } else {
            recentSMC = nil
        }
        return [recentSMC, info.temperature].compactMap { $0 }.max()
    }

    private func readFreshSafetyTemperature(fallbackInfo: BatteryInfo? = nil) async -> Double? {
        var values: [Double] = []
        do {
            let value = Double(try await backend.readBatteryTemperature())
            cachedSMCTemperature = value
            cachedSMCTemperatureAt = Date()
            values.append(value)
        } catch {
            cachedSMCTemperature = nil
            cachedSMCTemperatureAt = nil
        }
        let freshInfo = monitor.readBatteryInfo() ?? fallbackInfo
        if let freshInfo {
            monitor.batteryInfo = freshInfo
            if let temperature = freshInfo.temperature { values.append(temperature) }
        }
        let value = values.max()
        lastTemperature = value
        return value
    }

    // MARK: - Heat Protection

    private func evaluateHeatProtection(using info: BatteryInfo) {
        let temperature = measuredTemperature(using: info)
        lastTemperature = temperature
        guard let temperature else {
            sensorError = "온도를 읽을 수 없어 Heat Protection이 degraded 상태입니다."
            refreshDisplayedError()
            if shouldAttemptHeatProtection {
                enterHeatProtection(previous: mode.restorableMode ?? .maintaining(limit: effectiveChargeLimit))
            }
            return
        }

        sensorError = nil
        refreshDisplayedError()
        let threshold = settings.heatProtectionThreshold
        if temperature > threshold {
            if case .transitioning(.restoringHeat(let previous)) = mode {
                enterHeatProtection(previous: previous, preemptingCurrentOperation: true)
            } else if shouldAttemptHeatProtection {
                enterHeatProtection(previous: mode.restorableMode ?? .maintaining(limit: effectiveChargeLimit))
            }
        } else if temperature <= threshold - 2 {
            if case .heatBlocked(let previous) = mode {
                restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: true)
            } else if case .failed(let previous?, _, true) = mode,
                      heatProtectionRetryAfter.map({ Date() >= $0 }) ?? true {
                restoreAfterHeatProtection(previous: previous, requiresSafeTemperature: true)
            }
        }
    }

    private var shouldAttemptHeatProtection: Bool {
        guard heatProtectionRetryAfter.map({ Date() >= $0 }) ?? true else { return false }
        switch mode {
        case .heatBlocked, .transitioning(.enteringHeat): return false
        default: return true
        }
    }

    private func enterHeatProtection(previous: RestorableChargeMode, preemptingCurrentOperation: Bool = true) {
        cancelPendingChargeLimit(reason: "Heat Protection이 Charge Limit 변경을 취소했습니다.")
        let backend = self.backend
        _ = runBattery(
            operation: "enable Heat Protection",
            transition: .enteringHeat(previous: previous),
            preemptCurrentOperation: preemptingCurrentOperation,
            controlsBlockedOnFailure: true,
            work: {
                try await backend.cancelLongRunningOperation()
                try await backend.disableCharging()
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.heatProtectionRetryAfter = nil
                self.monitor.allowSleep()
                self.mode = .heatBlocked(previous: previous)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.heatProtectionRetryAfter = Date().addingTimeInterval(10)
                self.mode = .failed(previous: previous, message: error.localizedDescription, controlsBlocked: true)
            }
        )
    }

    private func restoreAfterHeatProtection(previous: RestorableChargeMode, requiresSafeTemperature: Bool) {
        guard activeOperationID == nil else { return }
        let backend = self.backend
        let threshold = settings.heatProtectionThreshold
        _ = runBattery(
            operation: "restore after Heat Protection",
            transition: .restoringHeat(previous: previous),
            controlsBlockedOnFailure: true,
            work: { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    if requiresSafeTemperature {
                        guard let preflight = await self.readFreshSafetyTemperature(), preflight <= threshold - 2 else {
                            throw BatteryError.commandFailed("Heat Protection restore", -1, "fresh temperature is unavailable or above the restore threshold")
                        }
                    }
                    switch previous {
                    case .maintaining(let limit): try await backend.applyMaintain(level: limit)
                    case .toppingUp: try await backend.startTopUp(to: 100)
                    case .discharging(let target, _): try await backend.startDischarge(to: target)
                    }
                    if requiresSafeTemperature {
                        guard let postflight = await self.readFreshSafetyTemperature(), postflight <= threshold else {
                            throw BatteryError.commandFailed("Heat Protection restore", -1, "post-restore temperature is unavailable or unsafe")
                        }
                    }
                } catch {
                    let restoreError = error
                    do {
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
                    self.mode = .failed(previous: previous, message: error.localizedDescription, controlsBlocked: true)
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

    // MARK: - User actions

    func setChargeLimit(_ limit: Int) {
        guard isReady, activeOperationID == nil, !isTopUpActive, !isDischarging, !isHeatProtectionBlockingControls else {
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
                    try? await backend.applyMaintain(level: limit)
                    throw error
                }
            },
            onSuccess: { [weak self] in
                guard let self else { return }
                self.mode = .discharging(target: limit, returnLimit: limit)
                if !self.monitor.preventSleep(reason: "BatteryGuard: Discharge in progress") {
                    self.commandError = "Discharge는 시작했지만 절전 방지 설정에 실패했습니다."
                }
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
                    try? await backend.applyMaintain(level: returnLimit)
                    throw error
                }
            },
            onSuccess: { [weak self] in self?.mode = .toppingUp(returnLimit: returnLimit) }
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

    private func checkLongRunningOperation(expectedMode: ChargeMode, fallbackMessage: String) {
        guard !isCheckingLongRunningOperation else { return }
        isCheckingLongRunningOperation = true
        let backend = self.backend
        Task { [weak self] in
            let isActive = await backend.isLongRunningOperationActive()
            let result = isActive ? nil : await backend.longRunningOperationResult()
            guard let self else { return }
            self.isCheckingLongRunningOperation = false
            guard self.mode == expectedMode, !isActive else { return }
            let detail = result?.combinedOutput ?? ""
            let message = detail.isEmpty ? fallbackMessage : "\(fallbackMessage) \(detail)"
            let limit = expectedMode.restorableMode?.maintainLimit ?? self.effectiveChargeLimit
            self.recoverMaintainAfterUnexpectedExit(limit: limit, message: message)
        }
    }

    private func recoverMaintainAfterUnexpectedExit(limit: Int, message: String) {
        guard activeOperationID == nil else { return }
        monitor.allowSleep()
        let backend = self.backend
        _ = runBattery(
            operation: "recover maintain after unexpected process exit",
            transition: .recoveringMaintain(limit: limit),
            work: { try await backend.applyMaintain(level: limit) },
            onSuccess: { [weak self] in
                self?.mode = .maintaining(limit: limit)
                self?.commandError = message
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

    // MARK: - Sleep / Wake

    private func setupSleepWakeObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelPendingChargeLimit(reason: "Sleep으로 대기 중인 Charge Limit 변경이 취소됐습니다.") }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reconcileAfterWake() }
        }
    }

    private func reconcileAfterWake() async {
        guard !isShuttingDown else { return }
        readiness = .reconciling
        cachedSMCTemperature = nil
        cachedSMCTemperatureAt = nil
        ledIntent = nil
        let prior = mode.restorableMode ?? .maintaining(limit: effectiveChargeLimit)
        do {
            try await backend.requestCancellation()
            guard let freshInfo = monitor.readBatteryInfo() else {
                throw BatteryError.unsupported("Wake 후 최신 배터리 상태를 읽지 못했습니다.")
            }
            monitor.batteryInfo = freshInfo
            if settings.heatProtectionEnabled {
                let temperature = await readFreshSafetyTemperature(fallbackInfo: freshInfo)
                guard let temperature, temperature <= settings.heatProtectionThreshold else {
                    try await backend.disableCharging()
                    mode = .heatBlocked(previous: prior)
                    readiness = .ready
                    updateLED()
                    return
                }
            }
            let limit = prior.maintainLimit
            try await backend.applyMaintain(level: limit)
            mode = .maintaining(limit: limit)
            readiness = .ready
            updateLED()
        } catch {
            mode = .failed(previous: prior, message: error.localizedDescription, controlsBlocked: true)
            readiness = .failed(error.localizedDescription)
            commandError = "Wake reconciliation 실패: \(error.localizedDescription)"
            refreshDisplayedError()
        }
    }

    // MARK: - MagSafe LED

    private func updateLED() {
        let nextIntent: MagSafeLEDIntent
        if !settings.controlMagSafeLED {
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

    private func recordLEDError(_ error: Error) {
        ledError = "MagSafe LED 제어 실패: \(error.localizedDescription)"
        logger.error("MagSafe LED failure: \(error.localizedDescription, privacy: .public)")
        refreshDisplayedError()
    }

    private func refreshDisplayedError() {
        lastError = sensorError ?? commandError ?? ledError
    }
}
