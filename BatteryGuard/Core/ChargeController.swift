// ChargeController.swift
// Main-actor coordinator for battery measurements, verified CLI state, and UI intent.

import Foundation
import AppKit
import OSLog

enum ChargeControllerReadiness: Equatable {
    case initializing
    case ready
    case failed(String)
    case shuttingDown
}

@MainActor
final class ChargeController: ObservableObject {
    static let shared = ChargeController()
    private static let shutdownCleanupTimeout: TimeInterval = 5

    private enum RestorableMode: Equatable {
        case maintain(limit: Int)
        case topUp
        case discharge(target: Int)
    }

    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "ChargeControl")
    private let backend: ChargeBackend
    private let monitor: BatteryMonitor
    private let settings: UserSettings

    @Published private(set) var currentState: ChargeState = .notConnected
    @Published private(set) var isDischarging = false
    @Published private(set) var isTopUpActive = false
    @Published private(set) var heatProtectionTriggered = false
    @Published private(set) var lastError: String?
    @Published private(set) var isCommandPending = false
    @Published private(set) var isChargeLimitPending = false
    @Published private(set) var pendingChargeLimit: Int?
    @Published private(set) var effectiveChargeLimit: Int
    @Published private(set) var readiness: ChargeControllerReadiness

    var displayedChargeLimit: Int { pendingChargeLimit ?? effectiveChargeLimit }
    var isReady: Bool { readiness == .ready }
    var isHeatProtectionBlockingControls: Bool {
        guard settings.heatProtectionEnabled else { return false }
        guard let lastTemperature else { return true }
        return heatProtectionTriggered ||
            heatProtectionPending ||
            heatRestorePending ||
            lastTemperature > settings.heatProtectionThreshold
    }

    private var commandError: String?
    private var sensorError: String?
    private var ledError: String?

    private var controlTimer: Timer?
    private var smcTemperatureTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var chargeLimitDebounceWork: DispatchWorkItem?
    private var initialMaintainDeferred = false
    private var isShuttingDown = false

    private var operationGeneration: UInt64 = 0
    private var activeOperationID: UInt64?
    private var isCheckingLongRunningOperation = false

    private var cachedSMCTemperature: Double?
    private var cachedSMCTemperatureAt: Date?
    private var lastTemperature: Double?

    private var heatProtectionPending = false
    private var heatRestorePending = false
    private var heatRestoreMode: RestorableMode?
    private var heatProtectionRetryAfter: Date?

    private var lastLEDState: MagSafeLEDState?
    private var isLEDBlinking = false
    private var hasControlledLED = false
    private(set) var magSafeLED: MagSafeLEDController?

    init(
        backend: ChargeBackend = SMCKit.shared,
        monitor: BatteryMonitor = BatteryMonitor.shared,
        settings: UserSettings = UserSettings.shared,
        initialReadiness: ChargeControllerReadiness = .initializing
    ) {
        self.backend = backend
        self.monitor = monitor
        self.settings = settings
        self.effectiveChargeLimit = settings.chargeLimit
        self.readiness = initialReadiness
        self.magSafeLED = MagSafeLEDController(backend: backend)
    }

    // MARK: - Lifecycle

    func initialize() async throws {
        guard readiness != .shuttingDown else { throw CancellationError() }
        readiness = .initializing
        do {
            try await performInitialization()
            guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
            readiness = .ready
        } catch {
            if !isShuttingDown, !Task.isCancelled {
                cleanupAfterFailedInitialization()
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
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func performInitialization() async throws {
        let desiredLimit = settings.chargeLimit
        try await backend.open()
        let observedStatus = try await backend.readControlStatus()
        if let observedLimit = observedStatus.maintainLevel,
           UserSettings.chargeLimitRange.contains(observedLimit) {
            effectiveChargeLimit = observedLimit
        }
        monitor.startMonitoring()

        guard let info = monitor.batteryInfo else {
            monitor.stopMonitoring()
            throw BatteryError.unsupported(
                "배터리 상태를 확인할 수 없어 초기 충전 상태를 안전하게 설정하지 않았습니다."
            )
        }

        startDisplayLoop()
        startSMCTemperatureLoop()
        setupSleepWakeObservers()

        if settings.heatProtectionEnabled {
            evaluateHeatProtection(using: info)
            guard lastTemperature != nil else {
                initialMaintainDeferred = true
                return
            }
            guard !heatProtectionTriggered, !heatProtectionPending else { return }
        }

        let validated = UserSettings.validatedChargeLimit(desiredLimit)
        try await backend.applyMaintain(level: validated)
        effectiveChargeLimit = validated
        settings.chargeLimit = validated
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        readiness = .shuttingDown

        controlTimer?.invalidate()
        smcTemperatureTimer?.invalidate()
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
        isChargeLimitPending = false
        monitor.stopMonitoring()
        monitor.allowSleep()
        let shouldRestoreLED = hasControlledLED || isLEDBlinking
        magSafeLED?.stopBlink()
        isLEDBlinking = false

        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }

        let backend = self.backend
        let logger = self.logger
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await backend.requestCancellation()
                if shouldRestoreLED { try await backend.restoreMagSafeLED() }
            } catch {
                logger.error("Shutdown cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + Self.shutdownCleanupTimeout) == .timedOut {
            logger.error("Shutdown cleanup timed out")
        }

        // Maintain is intentionally persistent and is not stopped on normal app quit.
        print("[ChargeController] Shutdown complete")
    }

    // MARK: - Serialized operations

    @discardableResult
    private func runBattery(
        operation: String,
        preemptCurrentOperation: Bool = false,
        clearCommandErrorOnSuccess: Bool = true,
        work: @escaping () async throws -> Void,
        completion: ((Result<Void, Error>) -> Void)? = nil
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
        isCommandPending = true

        let logger = self.logger
        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                if preemptCurrentOperation {
                    try await self?.backend.requestCancellation()
                }
                try await work()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            guard let self, self.activeOperationID == operationID else { return }
            self.activeOperationID = nil
            self.isCommandPending = false

            switch result {
            case .success:
                if clearCommandErrorOnSuccess { self.commandError = nil }
            case .failure(let error):
                self.commandError = "\(operation): \(error.localizedDescription)"
                logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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
        guard settings.heatProtectionEnabled else { return }
        let backend = self.backend
        Task { [weak self] in
            let result: Result<Double, Error>
            do { result = .success(Double(try await backend.readBatteryTemperature())) }
            catch { result = .failure(error) }
            guard let self else { return }
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

    /// Internal for deterministic tests; production feeds this from BatteryMonitor.
    func processBatteryInfo(_ info: BatteryInfo) {
        let pluggedIn = info.isPluggedIn || isDischarging || isTopUpActive
        guard pluggedIn else {
            currentState = .notConnected
            restoreOriginalLEDIfNeeded()
            return
        }

        if settings.heatProtectionEnabled {
            evaluateHeatProtection(using: info)
            if heatProtectionTriggered || heatProtectionPending || heatRestorePending {
                currentState = .chargingPaused
                updateLED()
                return
            }
        } else {
            sensorError = nil
            refreshDisplayedError()
            if heatProtectionTriggered {
                restoreAfterHeatProtection(reason: "Heat Protection disabled")
                currentState = .chargingPaused
                updateLED()
                return
            }
        }

        if initialMaintainDeferred,
           !isCommandPending,
           (!settings.heatProtectionEnabled || lastTemperature != nil) {
            initialMaintainDeferred = false
            applyMaintain(
                limit: settings.chargeLimit,
                operation: "deferred initial maintain",
                updateStoredLimit: true
            )
        }

        if isTopUpActive {
            if info.currentCharge >= 100 {
                completeTopUp()
            } else {
                currentState = .topUp
                updateLED()
                checkLongRunningOperation("Top Up 프로세스가 목표 도달 전에 종료되었습니다.")
                return
            }
        }

        if isDischarging {
            if info.currentCharge <= effectiveChargeLimit {
                completeDischarge()
            } else {
                currentState = .discharging
                updateLED()
                checkLongRunningOperation("Discharge 프로세스가 목표 도달 전에 종료되었습니다.")
                return
            }
        }

        currentState = info.isCharging && info.currentCharge < effectiveChargeLimit
            ? .charging
            : .chargingPaused
        updateLED()
    }

    // MARK: - Heat Protection

    private func evaluateHeatProtection(using batteryInfo: BatteryInfo) {
        let recentSMCTemperature: Double?
        if let cachedSMCTemperature,
           let cachedSMCTemperatureAt,
           Date().timeIntervalSince(cachedSMCTemperatureAt) <= 15 {
            recentSMCTemperature = cachedSMCTemperature
        } else {
            recentSMCTemperature = nil
        }

        let values = [recentSMCTemperature, batteryInfo.temperature].compactMap { $0 }
        guard let measuredTemperature = values.max() else {
            lastTemperature = nil
            sensorError = "온도를 읽을 수 없어 Heat Protection이 degraded 상태입니다."
            refreshDisplayedError()
            if !heatProtectionTriggered,
               !heatProtectionPending,
               heatProtectionRetryAfter.map({ Date() >= $0 }) ?? true {
                activateHeatProtection(preemptingRestore: false)
            }
            return
        }

        lastTemperature = measuredTemperature
        sensorError = nil
        refreshDisplayedError()

        let threshold = settings.heatProtectionThreshold
        if measuredTemperature > threshold {
            if heatRestorePending {
                activateHeatProtection(preemptingRestore: true)
            } else if !heatProtectionTriggered,
                      !heatProtectionPending,
                      heatProtectionRetryAfter.map({ Date() >= $0 }) ?? true {
                activateHeatProtection(preemptingRestore: false)
            }
        } else if measuredTemperature <= threshold - 2,
                  heatProtectionTriggered,
                  !heatProtectionPending,
                  !heatRestorePending {
            restoreAfterHeatProtection(reason: "temperature returned to safe range")
        }
    }

    private func activateHeatProtection(preemptingRestore: Bool) {
        cancelPendingChargeLimit(reason: "Heat Protection이 Charge Limit 변경을 취소했습니다.")

        if heatRestoreMode == nil {
            if isTopUpActive {
                heatRestoreMode = .topUp
            } else if isDischarging {
                heatRestoreMode = .discharge(target: effectiveChargeLimit)
            } else {
                heatRestoreMode = .maintain(limit: effectiveChargeLimit)
            }
        }

        heatRestorePending = false
        heatProtectionPending = true
        let backend = self.backend
        let enqueued = runBattery(
            operation: preemptingRestore ? "re-enable Heat Protection" : "enable Heat Protection",
            preemptCurrentOperation: true,
            work: {
                try await backend.cancelLongRunningOperation()
                try await backend.disableCharging()
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.heatProtectionPending = false
                if case .success = result {
                    self.heatProtectionRetryAfter = nil
                    self.isTopUpActive = false
                    self.isDischarging = false
                    self.monitor.allowSleep()
                    self.heatProtectionTriggered = true
                    self.currentState = .chargingPaused
                } else {
                    self.heatProtectionRetryAfter = Date().addingTimeInterval(10)
                    self.clearExclusiveStateIfLongOperationEnded()
                }
            }
        )
        if !enqueued { heatProtectionPending = false }
    }

    private func restoreAfterHeatProtection(reason: String) {
        guard heatProtectionTriggered, !heatProtectionPending, !heatRestorePending else { return }
        guard let restoreMode = heatRestoreMode else {
            commandError = "Heat Protection 이전 상태가 없어 자동 복원하지 않았습니다."
            refreshDisplayedError()
            return
        }

        heatRestorePending = true
        let backend = self.backend
        let threshold = settings.heatProtectionThreshold
        let fallbackTemperature = lastTemperature
        let requiresSafeTemperature = settings.heatProtectionEnabled

        let enqueued = runBattery(
            operation: "restore after Heat Protection (\(reason))",
            work: {
                if requiresSafeTemperature {
                    let measured = try? await backend.readBatteryTemperature()
                    let preflightTemperature = measured.map(Double.init) ?? fallbackTemperature
                    guard let preflightTemperature, preflightTemperature <= threshold - 2 else {
                        throw BatteryError.commandFailed("Heat Protection restore", -1, "temperature is not safely below the restore threshold")
                    }
                }

                switch restoreMode {
                case .maintain(let limit):
                    try await backend.applyMaintain(level: limit)
                case .topUp:
                    try await backend.startTopUp(to: 100)
                case .discharge(let target):
                    try await backend.startDischarge(to: target)
                }

                let postflightTemperature = try? await backend.readBatteryTemperature()
                if requiresSafeTemperature,
                   let postflightTemperature = postflightTemperature.map(Double.init),
                   postflightTemperature > threshold {
                    try await backend.disableCharging()
                    throw BatteryError.commandFailed("Heat Protection restore", -1, "temperature rose during restore; charging was disabled again")
                }
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.heatRestorePending = false
                guard case .success = result else { return }

                self.heatProtectionTriggered = false
                self.heatRestoreMode = nil
                switch restoreMode {
                case .maintain(let limit):
                    self.effectiveChargeLimit = limit
                    self.settings.chargeLimit = limit
                    self.currentState = .chargingPaused
                case .topUp:
                    self.isTopUpActive = true
                    self.currentState = .topUp
                case .discharge:
                    self.isDischarging = true
                    self.currentState = .discharging
                    if !self.monitor.preventSleep(reason: "BatteryGuard: restored Discharge") {
                        self.commandError = "Discharge는 복원됐지만 절전 방지 설정에 실패했습니다."
                        self.refreshDisplayedError()
                    }
                }
            }
        )
        if !enqueued { heatRestorePending = false }
    }

    // MARK: - User actions

    func setChargeLimit(_ limit: Int) {
        guard isReady,
              !isCommandPending,
              !isDischarging,
              !isTopUpActive,
              !heatProtectionTriggered,
              !heatProtectionPending,
              !heatRestorePending,
              !isHeatProtectionBlockingControls else {
            commandError = "현재 실행 중인 배터리 작업이 끝난 뒤 Charge Limit을 변경하세요."
            refreshDisplayedError()
            return
        }

        let target = UserSettings.validatedChargeLimit(limit)
        pendingChargeLimit = target
        isChargeLimitPending = true
        chargeLimitDebounceWork?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.pendingChargeLimit == target else { return }
                self.chargeLimitDebounceWork = nil
                self.applyMaintain(
                    limit: target,
                    operation: "apply Charge Limit",
                    updateStoredLimit: true
                ) { [weak self] _ in
                    self?.pendingChargeLimit = nil
                    self?.isChargeLimitPending = false
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
        guard info.currentCharge > effectiveChargeLimit else { return }

        let backend = self.backend
        let target = effectiveChargeLimit
        runBattery(
            operation: "start Discharge",
            work: { try await backend.startDischarge(to: target) },
            completion: { [weak self] result in
                guard let self, case .success = result else { return }
                self.isDischarging = true
                self.currentState = .discharging
                if !self.monitor.preventSleep(reason: "BatteryGuard: Discharge in progress") {
                    self.commandError = "Discharge는 시작했지만 절전 방지 설정에 실패했습니다."
                    self.refreshDisplayedError()
                }
            }
        )
    }

    func stopDischarge() {
        guard isDischarging, !isCommandPending else { return }
        let backend = self.backend
        let limit = effectiveChargeLimit
        runBattery(
            operation: "stop Discharge and resume maintain",
            work: {
                try await backend.cancelLongRunningOperation()
                try await backend.applyMaintain(level: limit)
            },
            completion: { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.isDischarging = false
                    self.monitor.allowSleep()
                    self.currentState = .chargingPaused
                } else { self.clearExclusiveStateIfLongOperationEnded() }
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

        let backend = self.backend
        runBattery(
            operation: "start Top Up",
            work: { try await backend.startTopUp(to: 100) },
            completion: { [weak self] result in
                guard let self, case .success = result else { return }
                self.isTopUpActive = true
                self.currentState = .topUp
            }
        )
    }

    func cancelTopUp() {
        guard isTopUpActive, !isCommandPending else { return }
        let backend = self.backend
        let limit = effectiveChargeLimit
        runBattery(
            operation: "cancel Top Up and resume maintain",
            work: {
                try await backend.cancelLongRunningOperation()
                try await backend.applyMaintain(level: limit)
            },
            completion: { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.isTopUpActive = false
                    self.currentState = .chargingPaused
                } else { self.clearExclusiveStateIfLongOperationEnded() }
            }
        )
    }

    func toggleCharging() {
        guard isReady else {
            commandError = "BatteryGuard 초기화가 끝난 뒤 충전 상태를 변경하세요."
            refreshDisplayedError()
            return
        }
        guard !heatProtectionTriggered, !heatProtectionPending, !heatRestorePending else {
            commandError = "Heat Protection이 활성화된 동안 충전 상태를 변경할 수 없습니다."
            refreshDisplayedError()
            return
        }
        guard let info = monitor.batteryInfo else {
            commandError = "배터리 상태를 확인할 수 없습니다."
            refreshDisplayedError()
            return
        }
        setChargeLimit(currentState == .chargingPaused ? 100 : info.currentCharge)
    }

    private func canStartExclusiveAction(named action: String) -> Bool {
        guard isReady,
              !isCommandPending,
              !isChargeLimitPending,
              !isDischarging,
              !isTopUpActive,
              !heatProtectionTriggered,
              !heatProtectionPending,
              !heatRestorePending,
              !isHeatProtectionBlockingControls else {
            commandError = "Heat Protection 또는 다른 배터리 작업 중에는 \(action)를 시작할 수 없습니다."
            refreshDisplayedError()
            return false
        }
        return true
    }

    // MARK: - Operation helpers

    private func applyMaintain(
        limit: Int,
        operation: String,
        updateStoredLimit: Bool,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        let validated = UserSettings.validatedChargeLimit(limit)
        let backend = self.backend
        runBattery(
            operation: operation,
            work: { try await backend.applyMaintain(level: validated) },
            completion: { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.effectiveChargeLimit = validated
                    if updateStoredLimit { self.settings.chargeLimit = validated }
                }
                completion?(result)
            }
        )
    }

    private func completeTopUp() {
        guard isTopUpActive, !isCommandPending else { return }
        let backend = self.backend
        let limit = effectiveChargeLimit
        runBattery(
            operation: "complete Top Up and resume maintain",
            work: {
                try await backend.cancelLongRunningOperation()
                try await backend.applyMaintain(level: limit)
            },
            completion: { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.isTopUpActive = false
                    self.currentState = .chargingPaused
                } else { self.clearExclusiveStateIfLongOperationEnded() }
            }
        )
    }

    private func completeDischarge() {
        guard isDischarging, !isCommandPending else { return }
        let backend = self.backend
        let limit = effectiveChargeLimit
        runBattery(
            operation: "complete Discharge and resume maintain",
            work: {
                try await backend.cancelLongRunningOperation()
                try await backend.applyMaintain(level: limit)
            },
            completion: { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.isDischarging = false
                    self.monitor.allowSleep()
                    self.currentState = .chargingPaused
                } else { self.clearExclusiveStateIfLongOperationEnded() }
            }
        )
    }

    private func handleUnexpectedLongOperationEnd(_ message: String) {
        guard !isCommandPending else { return }
        isTopUpActive = false
        isDischarging = false
        monitor.allowSleep()
        let backend = self.backend
        let limit = effectiveChargeLimit
        runBattery(
            operation: "recover maintain after unexpected process exit",
            clearCommandErrorOnSuccess: false,
            work: { try await backend.applyMaintain(level: limit) },
            completion: { [weak self] _ in
                self?.commandError = message
                self?.refreshDisplayedError()
            }
        )
    }

    private func checkLongRunningOperation(_ fallbackMessage: String) {
        guard !isCheckingLongRunningOperation else { return }
        isCheckingLongRunningOperation = true
        let backend = self.backend
        Task { [weak self] in
            let isActive = await backend.isLongRunningOperationActive()
            let result = isActive ? nil : await backend.longRunningOperationResult()
            guard let self else { return }
            self.isCheckingLongRunningOperation = false
            guard !isActive, self.isTopUpActive || self.isDischarging else { return }
            let detail = result?.combinedOutput ?? ""
            self.handleUnexpectedLongOperationEnd(
                detail.isEmpty ? fallbackMessage : "\(fallbackMessage) \(detail)"
            )
        }
    }

    private func clearExclusiveStateIfLongOperationEnded() {
        let backend = self.backend
        Task { [weak self] in
            let isActive = await backend.isLongRunningOperationActive()
            guard !isActive, let self else { return }
            self.isTopUpActive = false
            self.isDischarging = false
            self.monitor.allowSleep()
            self.currentState = .chargingPaused
        }
    }

    private func cancelPendingChargeLimit(reason: String) {
        guard isChargeLimitPending || pendingChargeLimit != nil else { return }
        chargeLimitDebounceWork?.cancel()
        chargeLimitDebounceWork = nil
        pendingChargeLimit = nil
        isChargeLimitPending = false
        commandError = reason
        refreshDisplayedError()
    }

    // MARK: - Sleep / Wake

    private func setupSleepWakeObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[ChargeController] System will sleep")
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileAfterWake() }
        }
    }

    private func reconcileAfterWake() {
        cachedSMCTemperature = nil
        cachedSMCTemperatureAt = nil
        lastLEDState = nil

        let backend = self.backend
        Task { [weak self] in
            let measured = try? await backend.readBatteryTemperature()
            let smcTemperature = measured.map(Double.init)
            guard let self else { return }
            if let smcTemperature {
                self.cachedSMCTemperature = smcTemperature
                self.cachedSMCTemperatureAt = Date()
            }

            guard let freshInfo = self.monitor.readBatteryInfo() else {
                self.sensorError = "Wake 후 최신 배터리 상태를 읽지 못해 충전 명령을 실행하지 않았습니다."
                self.refreshDisplayedError()
                return
            }
            self.monitor.batteryInfo = freshInfo

            if self.settings.heatProtectionEnabled {
                self.evaluateHeatProtection(using: freshInfo)
                guard self.lastTemperature != nil,
                      !self.heatProtectionTriggered,
                      !self.heatProtectionPending,
                      !self.heatRestorePending else { return }
            }

            self.applyMaintain(
                limit: self.effectiveChargeLimit,
                operation: "restore maintain after wake",
                updateStoredLimit: false
            )
        }
    }

    // MARK: - MagSafe LED

    private func updateLED() {
        guard settings.controlMagSafeLED else {
            restoreOriginalLEDIfNeeded()
            return
        }

        switch currentState {
        case .charging, .topUp:
            setLEDIfChanged(.orange)
        case .chargingPaused:
            setLEDIfChanged(.green)
        case .discharging:
            if !isLEDBlinking {
                isLEDBlinking = true
                hasControlledLED = true
                lastLEDState = nil
                magSafeLED?.startBlink { [weak self] error in
                    Task { @MainActor in self?.recordLEDError(error) }
                }
            }
        case .notConnected:
            restoreOriginalLEDIfNeeded()
        }
    }

    private func setLEDIfChanged(_ state: MagSafeLEDState) {
        if isLEDBlinking {
            isLEDBlinking = false
            magSafeLED?.stopBlink()
        }
        guard state != lastLEDState else { return }
        hasControlledLED = true
        lastLEDState = state

        let backend = self.backend
        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await backend.setMagSafeLED(state)
                result = .success(())
            } catch { result = .failure(error) }
            guard let self else { return }
            switch result {
            case .success:
                self.ledError = nil
            case .failure(let error):
                self.lastLEDState = nil
                self.recordLEDError(error)
            }
            self.refreshDisplayedError()
        }
    }

    private func restoreOriginalLEDIfNeeded() {
        if isLEDBlinking {
            isLEDBlinking = false
            magSafeLED?.stopBlink()
        }
        guard hasControlledLED else { return }

        let backend = self.backend
        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await backend.restoreMagSafeLED()
                result = .success(())
            } catch { result = .failure(error) }
            guard let self else { return }
            switch result {
            case .success:
                self.lastLEDState = nil
                self.hasControlledLED = false
                self.ledError = nil
            case .failure(let error):
                self.recordLEDError(error)
            }
            self.refreshDisplayedError()
        }
    }

    private func recordLEDError(_ error: Error) {
        ledError = "MagSafe LED 제어 실패: \(error.localizedDescription)"
        logger.error("MagSafe LED failure: \(error.localizedDescription, privacy: .public)")
        refreshDisplayedError()
    }

    // MARK: - Error domains

    private func refreshDisplayedError() {
        lastError = sensorError ?? commandError ?? ledError
    }
}
