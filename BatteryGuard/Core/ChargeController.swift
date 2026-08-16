// ChargeController.swift
// Main-actor state machine for measurements, verified CLI state, and UI intent.

import Foundation
import AppKit
import Combine
import OSLog

@MainActor
final class ChargeController: ObservableObject {
    static let shared = ChargeController(history: .shared, diagnostics: .shared)
    private static let defaultReconciliationInterval: TimeInterval = 60
    private static let minimumReconciliationInterval: TimeInterval = 1
    nonisolated static let smcTemperatureSamplingInterval: TimeInterval = 5
    private static let defaultLongRunningHeartbeatInterval: TimeInterval = 30
    private static let minimumLongRunningHeartbeatInterval: TimeInterval = 0.05
    static let longRunningExitSettlementDelays: [UInt64] = [
        100_000_000,
        250_000_000,
        500_000_000
    ]
    private static let defaultHistoryHeartbeatInterval: TimeInterval = 15 * 60
    private static let minimumHistoryHeartbeatInterval: TimeInterval = 0.05

    struct ControlMeasurement: Equatable {
        let currentCharge: Int
        let isCharging: Bool
        let isPluggedIn: Bool
        let isPresent: Bool
        let temperature: Double?

        init?(_ info: BatteryInfo?) {
            guard let info else { return nil }
            currentCharge = info.currentCharge
            isCharging = info.isCharging
            isPluggedIn = info.isPluggedIn
            isPresent = info.isPresent
            temperature = info.temperature
        }
    }

    struct FreshSafetyTemperatureRead {
        let maximum: Double?
        let failures: [String]

        func permitsAutomaticCharging(upTo threshold: Double) -> Bool {
            failures.isEmpty && maximum.map { $0 <= threshold } == true
        }
    }

    struct HeatRestoreReblockedError: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "Heat Protection restore failed and charging was blocked again: \(underlying.localizedDescription)"
        }
    }

    struct ControlCompensationError: LocalizedError {
        let operationError: Error
        let compensationError: Error

        var errorDescription: String? {
            "operation failed: \(operationError.localizedDescription); verified Maintain recovery failed: \(compensationError.localizedDescription)"
        }
    }

    // Swift requires module access for state shared by extensions in separate
    // files. These remain ChargeController implementation details; callers
    // should use the intent methods and read-only presentation properties.
    let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "ChargeControl")
    let backend: ChargeBackend
    let monitor: BatteryMonitor
    let settings: UserSettings
    let history: BatteryHistory?
    let diagnostics: DiagnosticLog
    let systemPowerObserver: SystemPowerObserving
    let runsSystemPowerObservation: Bool
    let reconciliationInterval: TimeInterval
    let smcTemperatureSamplingInterval: TimeInterval
    let longRunningHeartbeatInterval: TimeInterval
    let historyHeartbeatInterval: TimeInterval
    let now: @Sendable () -> Date

    @Published var mode: ChargeMode = .idle {
        didSet {
            synchronizeLongRunningMonitoring()
            recordHistoryAfterStableModeTransition(from: oldValue)
        }
    }
    @Published var lastError: String?
    @Published var pendingChargeLimit: Int?
    @Published var readiness: ChargeControllerReadiness
    @Published var isReconcilingExternalState = false
    @Published var sleepProtectionState: SleepChargingProtectionState
    @Published var issues: [BatteryIssue] = []
    @Published var safetyTemperatureSnapshot: SafetyTemperatureSnapshot = .unavailable

    var isReady: Bool { readiness == .ready }
    var isCommandPending: Bool {
        if isReconcilingExternalState { return true }
        if activeOperationID != nil { return true }
        if sleepPreparationTask != nil { return true }
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
    var heatProtectionPhase: HeatProtectionPhase {
        guard settings.heatProtectionEnabled else { return .disabled }
        switch mode {
        case .transitioning(.enteringHeat): return .entering
        case .transitioning(.restoringHeat): return .restoring
        case .heatBlocked: return .blocked
        case .failed(_, _, .heatProtection): return .failed
        default:
            return safetyTemperatureSnapshot.freshness == .fresh &&
                safetyTemperatureSnapshot.failures.isEmpty ? .monitoring : .degraded
        }
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
    var chargeLimitAvailability: ChargeActionAvailability {
        actionAvailability(
            alsoRequiresNoPendingLimit: false,
            conflicts: isDischarging || isTopUpActive
        )
    }
    var topUpAvailability: ChargeActionAvailability {
        actionAvailability(
            alsoRequiresNoPendingLimit: true,
            conflicts: isDischarging
        )
    }
    var dischargeAvailability: ChargeActionAvailability {
        actionAvailability(
            alsoRequiresNoPendingLimit: true,
            conflicts: isTopUpActive
        )
    }
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
        case .sleepProtected: return .chargingPaused
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
    var manualInterventionRecoveryDescription: String? {
        guard case .failed(let previous?, _, .manualIntervention) = mode else { return nil }
        let expected = manualRecoveryExpectation(for: previous)
        return "실제 CLI 상태를 \(expected.userDescription)(으)로 복원한 뒤 안전 상태를 다시 확인하세요."
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

    var issueRegistry = BatteryIssueRegistry()
    var commandError: String? {
        get { issueRegistry.message(for: .command) }
        set { issueRegistry.set(.command, severity: .critical, message: newValue, at: now()) }
    }
    var sensorError: String? {
        get { issueRegistry.message(for: .sensor) }
        set { issueRegistry.set(.sensor, severity: .warning, message: newValue, at: now()) }
    }
    var ledError: String? {
        get { issueRegistry.message(for: .led) }
        set { issueRegistry.set(.led, severity: .warning, message: newValue, at: now()) }
    }
    var driftError: String? {
        get { issueRegistry.message(for: .externalDrift) }
        set { issueRegistry.set(.externalDrift, severity: .blocking, message: newValue, at: now()) }
    }
    var batteryInfoObservation: AnyCancellable?
    var smcTemperatureTimer: Timer?
    var longRunningHeartbeatTimer: Timer?
    var longRunningExitObservationTask: Task<Void, Never>?
    var historyHeartbeatTimer: Timer?
    var reconciliationTimer: Timer?
    var activationObserver: NSObjectProtocol?
    var wakeFallbackObserver: NSObjectProtocol?
    var chargeLimitDebounceWork: DispatchWorkItem?
    var isShuttingDown = false
    var initializationInProgress = false
    var initializationCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    var backendAvailableForShutdown: Bool
    var initializationHardwareMutationAttempted: Bool
    var operationGeneration: UInt64 = 0
    var activeOperationID: UInt64?
    var activeOperationTask: Task<Void, Never>?
    var longRunningCheckGeneration: UInt64 = 0
    var longRunningCheckTask: Task<Void, Never>?
    var safetyTemperatureCache = SafetyTemperatureCache()
    var smcTemperatureFailure: String?
    var lastTemperature: Double?
    var smcTemperatureSampleGeneration: UInt64 = 0
    var smcTemperatureSampleTask: Task<Void, Never>?
    var lastSMCTemperatureSampleStartedAt: Date?
    var sampleAfterHeatEnableGeneration: UInt64?
    var heatProtectionRetryAfter: Date?
    var ledIntent: MagSafeLEDIntent?
    var ledGeneration: UInt64 = 0
    var systemPowerObservationError: String?
    var sleepPreparationGeneration: UInt64 = 0
    var sleepPreparationTask: Task<Bool, Never>?
    var sleepChargingOffWasRequested = false
    var magSafeLED: MagSafeLEDController

    init(
        backend: ChargeBackend = SMCKit.shared,
        monitor: BatteryMonitor? = nil,
        settings: UserSettings? = nil,
        initialReadiness: ChargeControllerReadiness = .initializing,
        initialMode: ChargeMode? = nil,
        history: BatteryHistory? = nil,
        reconciliationInterval: TimeInterval = 60,
        smcTemperatureSamplingInterval: TimeInterval = ChargeController.smcTemperatureSamplingInterval,
        longRunningHeartbeatInterval: TimeInterval = 30,
        historyHeartbeatInterval: TimeInterval = 15 * 60,
        diagnostics: DiagnosticLog = .disabled,
        systemPowerObserver: SystemPowerObserving = SystemPowerObserver(),
        runsSystemPowerObservation: Bool = !AppRuntime.isRunningTests,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let resolvedMonitor = monitor ?? BatteryMonitor.shared
        let resolvedSettings = settings ?? UserSettings.shared
        self.backend = backend
        self.monitor = resolvedMonitor
        self.settings = resolvedSettings
        self.history = history
        self.diagnostics = diagnostics
        self.systemPowerObserver = systemPowerObserver
        self.runsSystemPowerObservation = runsSystemPowerObservation
        self.now = now
        self.reconciliationInterval = reconciliationInterval.isFinite
            ? max(Self.minimumReconciliationInterval, reconciliationInterval)
            : Self.defaultReconciliationInterval
        self.smcTemperatureSamplingInterval = smcTemperatureSamplingInterval.isFinite
            ? max(0.05, smcTemperatureSamplingInterval)
            : Self.smcTemperatureSamplingInterval
        self.longRunningHeartbeatInterval = longRunningHeartbeatInterval.isFinite
            ? max(Self.minimumLongRunningHeartbeatInterval, longRunningHeartbeatInterval)
            : Self.defaultLongRunningHeartbeatInterval
        self.historyHeartbeatInterval = historyHeartbeatInterval.isFinite
            ? max(Self.minimumHistoryHeartbeatInterval, historyHeartbeatInterval)
            : Self.defaultHistoryHeartbeatInterval
        self.readiness = initialReadiness
        self.backendAvailableForShutdown = initialReadiness == .ready
        self.initializationHardwareMutationAttempted = initialReadiness == .ready
        self.mode = initialMode ?? (initialReadiness == .ready
            ? .maintaining(limit: UserSettings.validatedChargeLimit(resolvedSettings.chargeLimit))
            : .idle)
        self.sleepProtectionState = resolvedSettings.sleepChargingStrategy == .disabled
            ? .inactive
            : .ready
        self.magSafeLED = MagSafeLEDController(backend: backend)
    }

    // MARK: - Serialized operations

    @discardableResult
    func runBattery(
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

}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
