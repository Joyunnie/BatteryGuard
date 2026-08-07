import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
final class ChargeControllerSafetyTests: XCTestCase {
    private func makeSUT(
        heatProtectionEnabled: Bool = false,
        temperature: Double? = 30,
        charge: Int = 80,
        isCharging: Bool = false,
        initialMode: ChargeMode? = nil,
        history: BatteryHistory? = nil,
        diagnostics: DiagnosticLog = .disabled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> (ChargeController, FakeChargeBackend, BatteryMonitor, UserSettings) {
        let backend = FakeChargeBackend()
        backend.temperature = temperature.map(Float.init)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { nil },
            runsMonitoringInfrastructure: false,
            preventSleepHandler: { _ in true },
            allowSleepHandler: {}
        )
        monitor.batteryInfo = makeBatteryInfo(
            charge: charge,
            isCharging: isCharging,
            temperature: temperature
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = heatProtectionEnabled
        return (
            ChargeController(
                backend: backend,
                monitor: monitor,
                settings: settings,
                initialReadiness: .ready,
                initialMode: initialMode,
                history: history,
                diagnostics: diagnostics,
                now: now
            ),
            backend,
            monitor,
            settings
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testControlsStayDisabledUntilInitializationAndInitialMaintainFinish() async throws {
        let backend = FakeChargeBackend()
        backend.openDelay = 0.2
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        let initialization = Task { try await controller.initialize() }
        let openStarted = await eventually { backend.operations.contains("open") }
        XCTAssertTrue(openStarted)
        XCTAssertEqual(controller.readiness, .initializing)

        controller.setChargeLimit(60)
        XCTAssertFalse(backend.operations.contains("maintain:60"))
        try await initialization.value

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertFalse(backend.operations.contains("maintain:60"))
    }

    func testInitializationBecomesReadyOnlyAfterHighTemperatureIsBlocked() async throws {
        let backend = FakeChargeBackend()
        backend.temperature = 45
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70, temperature: 45) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = true
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        try await controller.initialize()

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertTrue(controller.heatProtectionTriggered)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testInitializationFailureLeavesControlsUnavailable() async {
        let backend = FakeChargeBackend()
        backend.failNext("open")
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        do {
            try await controller.initialize()
            XCTFail("Expected initialization failure")
        } catch {
            guard case .failed = controller.readiness else {
                return XCTFail("Expected failed readiness, received \(controller.readiness)")
            }
        }

        controller.startTopUp()
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("top-up") }))
    }

    func testPreflightFailureCanShutdownWithoutCallingUnavailableBackendAgain() async throws {
        let backend = FakeChargeBackend()
        backend.failNext("open")
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        do {
            try await controller.initialize()
            XCTFail("Expected initialization failure")
        } catch {}

        try await controller.shutdown()

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertEqual(backend.operations, ["open"])
    }

    func testInitializationFailureBeforeFirstHardwareMutationUsesLocalShutdown() async throws {
        let backend = FakeChargeBackend()
        let monitor = BatteryMonitor(
            batteryInfoProvider: { nil },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        do {
            try await controller.initialize()
            XCTFail("Expected missing battery state to fail initialization")
        } catch {}
        let operationsBeforeShutdown = backend.operations

        try await controller.shutdown()

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertEqual(backend.operations, operationsBeforeShutdown)
        XCTAssertFalse(backend.operations.contains("disable-charging"))
    }

    func testChargeLimitCommitsOnlyAfterVerifiedBackendSuccess() async {
        let (controller, backend, _, settings) = makeSUT()

        controller.setChargeLimit(60)
        XCTAssertEqual(controller.displayedChargeLimit, 60)
        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertEqual(controller.effectiveChargeLimit, 80)

        let completed = await eventually { !controller.isChargeLimitPending && !controller.isCommandPending }
        XCTAssertTrue(completed)
        XCTAssertEqual(settings.chargeLimit, 60)
        XCTAssertEqual(controller.effectiveChargeLimit, 60)
        XCTAssertTrue(backend.operations.contains("maintain:60"))
    }

    func testChargeLimitFailureRollsUIBackToVerifiedValue() async {
        let (controller, backend, _, settings) = makeSUT()
        backend.failNext("maintain")

        controller.setChargeLimit(55)
        let completed = await eventually { !controller.isChargeLimitPending && !controller.isCommandPending }

        XCTAssertTrue(completed)
        XCTAssertEqual(controller.displayedChargeLimit, 80)
        XCTAssertEqual(controller.effectiveChargeLimit, 80)
        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertNotNil(controller.lastError)
    }

    func testLongRunningLaunchFailureNeverEntersTopUpState() async {
        let (controller, backend, _, _) = makeSUT(charge: 70)
        backend.failNext("top-up")

        controller.startTopUp()
        let completed = await eventually { !controller.isCommandPending }

        XCTAssertTrue(completed)
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertNotEqual(controller.currentState, .topUp)
        XCTAssertNotNil(controller.lastError)
    }

    func testHeatProtectionPreemptsDischargeAndRequiresVerifiedDisable() async {
        let (controller, backend, monitor, settings) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 90
        )
        settings.chargeLimit = 80
        controller.processBatteryInfo(makeBatteryInfo(charge: 90, temperature: 30))

        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 90, isCharging: false, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)

        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)
        XCTAssertFalse(controller.isDischarging)
        XCTAssertTrue(backend.operations.contains("request-cancellation"))
        XCTAssertTrue(backend.operations.contains("cancel-long"))
        XCTAssertTrue(backend.operations.contains("disable-charging"))
    }

    func testHeatProtectionRestoresRecordedModeOnlyAfterSafeTemperature() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        let hotInfo = makeBatteryInfo(temperature: 45)
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        backend.temperature = 37
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)

        let restored = await eventually { !controller.heatProtectionTriggered && !controller.isCommandPending }
        XCTAssertTrue(restored)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertEqual(controller.effectiveChargeLimit, 80)
    }

    func testRisingTemperatureInvalidatesAnInFlightRestore() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        controller.processBatteryInfo(makeBatteryInfo(temperature: 45))
        let initiallyProtected = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(initiallyProtected)

        backend.maintainDelay = 0.25
        backend.temperature = 37
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)
        let restoreStarted = await eventually { backend.operations.contains("maintain:80") }
        XCTAssertTrue(restoreStarted)

        backend.temperature = 45
        let hotAgain = makeBatteryInfo(temperature: 45)
        monitor.batteryInfo = hotAgain
        controller.processBatteryInfo(hotAgain)

        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)
        XCTAssertGreaterThanOrEqual(
            backend.operations.filter { $0 == "disable-charging" }.count,
            2
        )
    }

    func testPreemptedCompletionIsRecordedAsSuperseded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-superseded-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 80,
            diagnostics: log
        )
        backend.maintainDelay = 0.25
        let safeInfo = makeBatteryInfo(charge: 80, temperature: 30)
        monitor.batteryInfo = safeInfo
        controller.processBatteryInfo(safeInfo)

        controller.setChargeLimit(60)
        let maintainStarted = await eventually(timeout: 2) {
            backend.operations.contains("maintain:60")
        }
        XCTAssertTrue(maintainStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 80, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if events.contains(where: { $0.outcome == .superseded }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            $0.operation == "apply Charge Limit" && $0.outcome == .superseded
        })
    }

    func testUnsafePostflightTemperatureReblocksInsteadOfPublishingRestoredMode() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        controller.processBatteryInfo(makeBatteryInfo(temperature: 45))
        let initiallyBlocked = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(initiallyBlocked)

        backend.enqueueTemperatures([37, nil])
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)

        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertFalse(controller.isDischarging)
        XCTAssertGreaterThanOrEqual(
            backend.operations.filter { $0 == "disable-charging" }.count,
            2
        )
    }

    func testMissingTemperatureBlocksAutomaticControlAndFailsClosed() async {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: nil,
            charge: 70
        )

        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: nil))
        controller.startTopUp()

        XCTAssertTrue(controller.lastError?.contains("degraded") == true)
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("top-up") }))
        let failedClosed = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(failedClosed)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
    }

    func testFailedHeatBlockKeepsConflictingControlsDisabled() async {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 70
        )
        backend.failNext("disable-charging")

        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: 45))
        let attemptFinished = await eventually { !controller.isCommandPending }
        XCTAssertTrue(attemptFinished)
        XCTAssertFalse(controller.heatProtectionTriggered)
        XCTAssertTrue(controller.isHeatProtectionBlockingControls)

        controller.startTopUp()
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("top-up") }))
    }

    func testHeatPreemptionDoesNotLetCancelledTopUpRestoreMaintain() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70
        )
        backend.topUpDelay = 0.3
        let safeInfo = makeBatteryInfo(charge: 70, temperature: 30)
        monitor.batteryInfo = safeInfo
        controller.processBatteryInfo(safeInfo)
        controller.startTopUp()
        let topUpStarted = await eventually { backend.operations.contains("top-up:100") }
        XCTAssertTrue(topUpStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 70, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        let operations = backend.operations
        let disabledAt = try? XCTUnwrap(operations.lastIndex(of: "disable-charging"))
        if let disabledAt {
            XCTAssertFalse(operations[operations.index(after: disabledAt)...].contains("maintain:80"))
        }
    }

    func testUnsafeTopUpRestoreCancelsTheNewLongOperationBeforeReblocking() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70
        )
        let safeInfo = makeBatteryInfo(charge: 70, temperature: 30)
        monitor.batteryInfo = safeInfo
        controller.processBatteryInfo(safeInfo)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 70, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        backend.enqueueTemperatures([37, nil])
        let coolInfo = makeBatteryInfo(charge: 70, temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)
        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)

        let longOperationIsActive = await backend.isLongRunningOperationActive()
        XCTAssertFalse(longOperationIsActive)
        XCTAssertGreaterThanOrEqual(
            backend.operations.filter { $0 == "cancel-long" }.count,
            2
        )
    }

    func testChangingThresholdDuringRestoreUsesTheLatestValue() async {
        let (controller, backend, monitor, settings) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        controller.processBatteryInfo(makeBatteryInfo(temperature: 45))
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        backend.maintainDelay = 0.25
        backend.temperature = 37
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)
        let restoreStarted = await eventually { backend.operations.contains("maintain:80") }
        XCTAssertTrue(restoreStarted)
        settings.heatProtectionThreshold = 35

        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)
    }

    func testSensorFailureIsLoggedAsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-sensor-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: nil,
            diagnostics: log
        )
        backend.temperature = nil

        controller.processBatteryInfo(makeBatteryInfo(temperature: nil))
        let deadline = Date().addingTimeInterval(1)
        var recorded = false
        while Date() < deadline, !recorded {
            let events = await log.recentEvents()
            recorded = events.contains {
                $0.category == .sensor && $0.outcome == .failed && $0.message?.contains("온도") == true
            }
            if !recorded { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(recorded)
    }

    func testHistoryRecordsVerifiedModeLimitInsteadOfStoredPreference() async throws {
        let history = BatteryHistory(inMemory: true)
        let historyReadiness = await history.waitUntilReady()
        XCTAssertEqual(historyReadiness, .ready)
        let (controller, _, _, settings) = makeSUT(history: history)
        settings.chargeLimit = 60

        controller.processBatteryInfo(makeBatteryInfo(charge: 75))
        let record = try XCTUnwrap(history.fetchLast24Hours().last)
        XCTAssertEqual(record.chargeLimit, 80)
    }

    func testExternalMaintainDriftIsDisplayedLoggedAndClearsWhenCorrected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-drift-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, backend, _, _) = makeSUT(diagnostics: log)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 7_777, target: 60)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertTrue(controller.hasExternalControlDrift)
        XCTAssertEqual(controller.effectiveChargeLimit, 80)
        XCTAssertTrue(controller.externalDriftDescription?.contains("기대: Maintain 80%") == true)
        XCTAssertTrue(controller.externalDriftDescription?.contains("실제: Maintain 60%") == true)
        XCTAssertTrue(controller.externalDriftDescription?.contains("60%") == true)
        XCTAssertTrue(controller.externalDriftRecoveryDescription?.contains("Maintain 80%") == true)
        XCTAssertTrue(controller.lastError?.contains("외부 CLI 변경 감지") == true)

        let driftWasLogged = await log.recentEvents().contains { $0.outcome == .drifted }
        XCTAssertTrue(driftWasLogged)

        await controller.reconcileExternalState()
        let repeatedEvents = await log.recentEvents()
        XCTAssertEqual(repeatedEvents.filter { $0.outcome == .drifted }.count, 1)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_888, target: 80)
            )
        )
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(controller.hasExternalControlDrift)
        XCTAssertNil(controller.externalDriftDescription)
    }

    func testUnknownChargingNeverQualifiesAsMaintain() async {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .unknown,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertTrue(controller.hasExternalControlDrift)
        XCTAssertEqual(controller.currentState, .unknown)
        XCTAssertTrue(controller.externalDriftDescription?.contains("모순된") == true)
    }

    func testUnknownAndDuplicateWorkersNeverQualifyAsMaintain() async {
        let (controller, backend, _, _) = makeSUT()
        let invalidWorkers: [MaintainWorkerStatus] = [
            .unknown,
            .duplicate(pids: [101, 202])
        ]

        for worker in invalidWorkers {
            backend.setControlStatus(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: worker
                )
            )
            await controller.reconcileExternalState()
            XCTAssertTrue(controller.hasExternalControlDrift)
        }
    }

    func testExternalDischargeAndStatusFailureNeverLookLikeConfirmedMaintain() async {
        let history = BatteryHistory(inMemory: true)
        let historyReadiness = await history.waitUntilReady()
        XCTAssertEqual(historyReadiness, .ready)
        let (controller, backend, _, _) = makeSUT(history: history)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: true,
                maintainLevel: 80,
                maintainWorker: .stopped
            )
        )

        await controller.reconcileExternalState()
        XCTAssertEqual(controller.currentState, .discharging)
        XCTAssertTrue(controller.hasExternalControlDrift)
        controller.processBatteryInfo(makeBatteryInfo(charge: 80))
        XCTAssertTrue(history.fetchLast24Hours().isEmpty)

        backend.setControlStatus(nil)
        backend.failNext("read-status")
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.currentState, .unknown)
        XCTAssertTrue(controller.externalDriftDescription?.contains("확인할 수 없음") == true)
    }

    func testAppActivationTriggersDriftReconciliation() async throws {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 80)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)
        try await controller.initialize()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 65,
                maintainWorker: .running(pid: 6_565, target: 65)
            )
        )

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        try await controller.shutdown()
    }

    func testPeriodicReconciliationDetectsTerminalDrift() async throws {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 80)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            reconciliationInterval: 1
        )
        try await controller.initialize()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 70,
                maintainWorker: .running(pid: 7_070, target: 70)
            )
        )

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        try await controller.shutdown()
    }

    func testLostTopUpOwnershipSurfacesExternalDriftWithoutOverwritingIt() async {
        let (controller, backend, monitor, _) = makeSUT(charge: 70)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)
        backend.setOwnedLongRunningOperation(false)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        let info = makeBatteryInfo(charge: 70)
        monitor.batteryInfo = info
        controller.processBatteryInfo(info)

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
        XCTAssertTrue(controller.externalDriftDescription?.contains("실제: 충전 명령 활성") == true)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testLostDischargeOwnershipSurfacesExternalDriftWithoutOverwritingIt() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        backend.setOwnedLongRunningOperation(false)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        let info = makeBatteryInfo(charge: 90)
        monitor.batteryInfo = info
        controller.processBatteryInfo(info)

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
        XCTAssertTrue(controller.externalDriftDescription?.contains("실제: 방전 명령 활성") == true)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testDischargeStartFailureRecordsMaintainAsPreviousAndBlocksIfRecoveryFails() async {
        let (controller, backend, _, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        backend.failNext("discharge")

        controller.startDischarge()
        let recoveredFailure = await eventually {
            if case .failed(let previous, _, let disposition) = controller.mode {
                return previous == .maintaining(limit: 80) && disposition == .recoverPrevious
            }
            return false
        }
        XCTAssertTrue(recoveredFailure)

        let (blockedController, blockedBackend, _, blockedSettings) = makeSUT(charge: 90)
        blockedSettings.chargeLimit = 80
        blockedBackend.failNext("discharge")
        blockedBackend.failNext("maintain")
        blockedController.startDischarge()
        let blockedFailure = await eventually {
            if case .failed(let previous, _, let disposition) = blockedController.mode {
                return previous == .maintaining(limit: 80) && disposition == .manualIntervention
            }
            return false
        }
        XCTAssertTrue(blockedFailure)
    }

    func testWakePreservesExternalDriftWithoutApplyingMaintain() async {
        let expectation = ReconciledChargeExpectation.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .externalDrift(
                expected: expectation,
                observed: .maintaining(limit: 60)
            )
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        await controller.reconcileAfterWake()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(expected: expectation, observed: .maintaining(limit: 60))
        )
        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
    }

    func testHeatBlockedDriftRecoversOnlyAfterChargingIsVerifiedDisabled() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(initialMode: .heatBlocked(previous: previous))
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 4_242, target: 80)
            )
        )

        await controller.reconcileExternalState()
        XCTAssertTrue(controller.hasExternalControlDrift)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: previous))
        XCTAssertFalse(controller.hasExternalControlDrift)
    }

    func testRecoverableFailureCanReturnToVerifiedPreviousMode() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, _, _, _) = makeSUT(
            initialMode: .failed(
                previous: previous,
                message: "temporary",
                disposition: .recoverPrevious
            )
        )

        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testHeatFailureOnlyRecoversToHeatBlockedAfterDisabledTupleIsVerified() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .failed(
                previous: previous,
                message: "temporary",
                disposition: .heatProtection
            )
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: previous))
    }

    func testManualFailureIsNotAutomaticallyRestoredByHeatProtection() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .failed(
                previous: previous,
                message: "hardware state unknown",
                disposition: .manualIntervention
            )
        )
        settings.heatProtectionEnabled = true
        let controlOperationsBefore = backend.operations.filter {
            $0.hasPrefix("maintain:") || $0.hasPrefix("top-up:") || $0.hasPrefix("discharge:")
        }

        controller.processBatteryInfo(makeBatteryInfo(temperature: 30))
        await Task.yield()

        XCTAssertEqual(
            backend.operations.filter {
                $0.hasPrefix("maintain:") || $0.hasPrefix("top-up:") || $0.hasPrefix("discharge:")
            },
            controlOperationsBefore
        )
        XCTAssertEqual(
            controller.mode,
            .failed(
                previous: previous,
                message: "hardware state unknown",
                disposition: .manualIntervention
            )
        )
    }

    func testStaleLongRunningProbeCannotMutateStateAfterShutdownStarts() async throws {
        let previous = RestorableChargeMode.toppingUp(returnLimit: 80)
        let (controller, backend, _, _) = makeSUT(
            charge: 70,
            initialMode: .toppingUp(returnLimit: 80)
        )
        backend.setLongRunningProbeDelay(0.25)

        controller.processBatteryInfo(makeBatteryInfo(charge: 70))
        let probeStarted = await eventually { backend.operations.contains("check-long-running") }
        XCTAssertTrue(probeStarted)

        try await controller.shutdown()
        await Task.yield()

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertEqual(controller.mode.restorableMode, previous)
        XCTAssertFalse(controller.hasExternalControlDrift)
    }

    func testStaleReconciliationCannotOverwriteWakeRecovery() async {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 80)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            initialReadiness: .ready
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        backend.setControlStatusDelay(0.15)

        let reconciliation = Task { await controller.reconcileExternalState() }
        let statusReadStarted = await eventually {
            backend.operations.contains("read-status")
        }
        XCTAssertTrue(statusReadStarted)

        await controller.reconcileAfterWake()
        await reconciliation.value

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(controller.hasExternalControlDrift)
    }

    func testExternalActiveOperationRejectsShutdownWithoutDisablingController() async throws {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        await controller.reconcileExternalState()

        do {
            try await controller.shutdown()
            XCTFail("Expected externally owned discharge to reject shutdown")
        } catch {
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.hasExternalControlDrift)
            XCTAssertFalse(backend.operations.contains("request-cancellation"))
        }

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        try await controller.shutdown()
    }

    func testShutdownRefreshesStaleDriftAndRejectsNewExternalDischarge() async {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        await controller.reconcileExternalState()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        do {
            try await controller.shutdown()
            XCTFail("Expected fresh external discharge to reject shutdown")
        } catch {
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.hasExternalControlDrift)
            XCTAssertTrue(controller.externalDriftDescription?.contains("방전 명령 활성") == true)
            XCTAssertFalse(backend.operations.contains("request-cancellation"))
        }
    }

    func testShutdownRejectsWhenFreshDriftStatusCannotBeReadAndRemainsRetryable() async throws {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        await controller.reconcileExternalState()
        backend.failNext("read-status")

        do {
            try await controller.shutdown()
            XCTFail("Expected unavailable shutdown status to reject shutdown")
        } catch {
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.hasExternalControlDrift)
            XCTAssertTrue(controller.externalDriftDescription?.contains("확인할 수 없음") == true)
            XCTAssertFalse(backend.operations.contains("request-cancellation"))
        }

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        try await controller.shutdown()
    }

    func testDisablingLEDControlRestoresCapturedStateThroughBackend() async {
        let (controller, backend, _, settings) = makeSUT(charge: 50, isCharging: true)
        settings.controlMagSafeLED = true
        controller.processBatteryInfo(makeBatteryInfo(charge: 50, isCharging: true))
        let LEDWasSet = await eventually { backend.operations.contains("set-led:04") }
        XCTAssertTrue(LEDWasSet)

        settings.controlMagSafeLED = false
        controller.processBatteryInfo(makeBatteryInfo(charge: 50, isCharging: true))
        let LEDWasRestored = await eventually { backend.operations.contains("restore-led") }
        XCTAssertTrue(LEDWasRestored)
    }

    func testDisablingLEDWhileDischargingRestoresInsteadOfLosingSnapshot() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.controlMagSafeLED = true
        settings.chargeLimit = 80

        controller.startDischarge()
        let started = await eventually { controller.isDischarging }
        XCTAssertTrue(started)
        let dischargeInfo = makeBatteryInfo(charge: 90)
        monitor.batteryInfo = dischargeInfo
        controller.processBatteryInfo(dischargeInfo)
        let blinkStarted = await eventually { backend.operations.contains("set-led:04") }
        XCTAssertTrue(blinkStarted)

        settings.controlMagSafeLED = false
        controller.processBatteryInfo(dischargeInfo)
        let restored = await eventually { backend.operations.contains("restore-led") }
        XCTAssertTrue(restored)
    }

    func testNormalShutdownDoesNotStopPersistentMaintain() async throws {
        let (controller, backend, _, _) = makeSUT()
        try await controller.shutdown()

        XCTAssertFalse(backend.operations.contains("stop-maintain"))
    }

    func testWakeReconciliationSupersedesAnInFlightMaintainCompletion() async {
        let backend = FakeChargeBackend()
        backend.maintainDelay = 0.25
        let info = makeBatteryInfo(charge: 80, temperature: 30)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            initialReadiness: .ready
        )

        controller.setChargeLimit(60)
        let maintainStarted = await eventually { backend.operations.contains("maintain:60") }
        XCTAssertTrue(maintainStarted)
        await controller.reconcileAfterWake()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertFalse(controller.isCommandPending)
        XCTAssertEqual(backend.operations.last(where: { $0.hasPrefix("maintain:") }), "maintain:80")
    }

    func testShutdownFailureDoesNotPretendCleanupSucceeded() async throws {
        let (controller, backend, _, _) = makeSUT(charge: 70)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)
        backend.failNext("maintain")

        do {
            try await controller.shutdown()
            XCTFail("Expected shutdown cleanup failure")
        } catch {
            XCTAssertTrue(controller.lastError?.contains("종료 안전 정리 실패") == true)
            XCTAssertEqual(controller.readiness, .ready)
            if case .failed(_, _, let disposition) = controller.mode {
                XCTAssertEqual(disposition, .manualIntervention)
            } else {
                XCTFail("Expected retryable failed state")
            }
        }


        try await controller.shutdown()
        XCTAssertEqual(controller.readiness, .shuttingDown)
    }

    func testFailedDischargeShutdownKeepsSleepPreventionUntilVerifiedRecovery() async throws {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        XCTAssertTrue(monitor.isSleepPreventionActive)
        backend.failNext("maintain")

        do {
            try await controller.shutdown()
            XCTFail("Expected shutdown cleanup failure")
        } catch {
            XCTAssertTrue(monitor.isSleepPreventionActive)
            XCTAssertEqual(controller.readiness, .ready)
        }

        try await controller.shutdown()
        XCTAssertFalse(monitor.isSleepPreventionActive)
    }

    func testShutdownDuringTopUpCancelsAndRestoresVerifiedMaintain() async throws {
        let (controller, backend, _, _) = makeSUT(charge: 70)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)

        try await controller.shutdown()

        XCTAssertTrue(backend.operations.contains("request-cancellation"))
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("read-status"))
    }

    func testShutdownDuringDischargeCancelsAndRestoresVerifiedMaintain() async throws {
        let (controller, backend, _, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)

        try await controller.shutdown()

        XCTAssertTrue(backend.operations.contains("request-cancellation"))
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("read-status"))
    }

    func testDisableBatteryGuardControlReleasesVerifiedControlAndPersistsMonitoringMode() async {
        let (controller, backend, _, settings) = makeSUT()
        settings.heatProtectionEnabled = true
        settings.controlMagSafeLED = true

        controller.disableBatteryGuardControl()

        let released = await eventually {
            controller.mode == .controlDisabled(lastLimit: 80)
        }
        XCTAssertTrue(released)
        XCTAssertTrue(backend.operations.contains("release-control"))
        XCTAssertFalse(settings.batteryControlEnabled)
        XCTAssertFalse(settings.heatProtectionEnabled)
        XCTAssertFalse(settings.controlMagSafeLED)
    }

    func testDisableBatteryGuardControlFailurePreservesReleasingOwnershipAndRetryPath() async {
        let (controller, backend, _, settings) = makeSUT()
        backend.failNext("release-control")

        controller.disableBatteryGuardControl()

        let failed = await eventually {
            if case .externalDrift(.controlReleasing(lastLimit: 80), .unavailable) = controller.mode {
                return true
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(settings.batteryControlEnabled)
        XCTAssertTrue(settings.batteryControlReleasePending)
        XCTAssertTrue(controller.isReleasedControlDrift)
    }

    func testDisableTransitionImmediatelyBlocksControllerOwnedFeatures() async {
        let (controller, backend, _, settings) = makeSUT()
        settings.heatProtectionEnabled = true
        backend.releaseDelay = 0.2

        controller.disableBatteryGuardControl()

        XCTAssertEqual(settings.batteryControlOwnership, .releasing(lastLimit: 80))
        XCTAssertTrue(controller.isBatteryControlDisabled)
        controller.setHeatProtectionEnabled(false)
        controller.setHeatProtectionEnabled(true)
        XCTAssertFalse(settings.heatProtectionEnabled)

        let released = await eventually { controller.mode == .controlDisabled(lastLimit: 80) }
        XCTAssertTrue(released)
        XCTAssertFalse(settings.heatProtectionEnabled)
    }

    func testShutdownCannotInvertOwnershipAfterReleaseWasDurablyCommitted() async throws {
        let (controller, backend, _, settings) = makeSUT()
        controller.setLEDControlEnabled(true)
        let ledWasCaptured = await eventually { backend.operations.contains("set-led:03") }
        XCTAssertTrue(ledWasCaptured)
        backend.restoreLEDDelay = 0.2

        controller.disableBatteryGuardControl()
        let releaseWasCommitted = await eventually {
            settings.batteryControlOwnership == .system(lastLimit: 80)
        }
        XCTAssertTrue(releaseWasCommitted)

        try await controller.shutdown()

        XCTAssertEqual(settings.batteryControlOwnership, .system(lastLimit: 80))
        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertFalse(settings.batteryControlReleasePending)
    }

    func testLEDRestoreFailureDoesNotBlockVerifiedBatteryShutdown() async throws {
        let (controller, backend, _, settings) = makeSUT(charge: 50, isCharging: true)
        settings.controlMagSafeLED = true
        controller.processBatteryInfo(makeBatteryInfo(charge: 50, isCharging: true))
        let ledWasCaptured = await eventually { backend.operations.contains("set-led:04") }
        XCTAssertTrue(ledWasCaptured)
        backend.failNext("restore-led")

        try await controller.shutdown()

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertTrue(controller.lastError?.contains("MagSafe LED 자동 복원 실패") == true)
        XCTAssertTrue(backend.operations.contains("request-cancellation"))
    }

    func testLEDRestoreFailureDoesNotBlockReleasedControlShutdown() async throws {
        let (controller, backend, _, settings) = makeSUT(charge: 50, isCharging: true)
        settings.controlMagSafeLED = true
        controller.processBatteryInfo(makeBatteryInfo(charge: 50, isCharging: true))
        let ledWasCaptured = await eventually { backend.operations.contains("set-led:04") }
        XCTAssertTrue(ledWasCaptured)
        try settings.completeBatteryControlRelease(lastLimit: 80)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        backend.failNext("restore-led")

        try await controller.shutdown()

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertEqual(settings.batteryControlOwnership, .system(lastLimit: 80))
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
    }

    func testReenablingHeatProtectionRejectsStaleCachedSMCTemperature() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let backend = FakeChargeBackend()
        backend.temperature = 30
        let info = makeBatteryInfo(charge: 70, temperature: nil)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = true
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            now: { clock.now() }
        )
        try await controller.initialize()
        monitor.batteryInfo = nil
        controller.setHeatProtectionEnabled(false)
        clock.advance(by: 16)

        controller.setHeatProtectionEnabled(true)

        let blocked = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(blocked)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        try await controller.shutdown()
    }

    func testEnableBatteryGuardControlEstablishesMaintainBeforePersistingOwnership() async throws {
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 75)
        )
        try settings.completeBatteryControlRelease(lastLimit: 75)

        controller.enableBatteryGuardControl()

        let enabled = await eventually { controller.mode == .maintaining(limit: 75) }
        XCTAssertTrue(enabled)
        XCTAssertTrue(backend.operations.contains("maintain:75"))
        XCTAssertTrue(settings.batteryControlEnabled)
        XCTAssertEqual(settings.batteryControlOwnership, .batteryGuard(lastLimit: 75))
    }

    func testEnableBatteryGuardControlFailurePreservesSystemOwnershipTruth() async throws {
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 75)
        )
        try settings.completeBatteryControlRelease(lastLimit: 75)
        backend.failNext("maintain")

        controller.enableBatteryGuardControl()

        let failed = await eventually {
            if case .externalDrift(.controlReleased(lastLimit: 75), .unavailable) = controller.mode {
                return true
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(settings.batteryControlOwnership, .system(lastLimit: 75))
        XCTAssertTrue(controller.isBatteryControlDisabled)
    }

    func testInitializationResumesPendingReleaseWithoutApplyingMaintain() async throws {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 70, isCharging: true)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        try settings.beginBatteryControlRelease(lastLimit: 80)
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings
        )

        try await controller.initialize()

        XCTAssertEqual(controller.mode, .controlDisabled(lastLimit: 80))
        XCTAssertFalse(settings.batteryControlEnabled)
        XCTAssertFalse(settings.batteryControlReleasePending)
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
        XCTAssertTrue(backend.operations.contains("release-control"))
        try await controller.shutdown()
    }

    func testInitializationOfSystemOwnershipAllowsNativePauseAndClearsControlSideEffects() async throws {
        let backend = FakeChargeBackend()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .stopped
            )
        )
        let monitor = BatteryMonitor(
            batteryInfoProvider: { nil },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        try settings.completeBatteryControlRelease(lastLimit: 80)
        settings.heatProtectionEnabled = true
        settings.controlMagSafeLED = true
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings
        )

        try await controller.initialize()

        XCTAssertEqual(controller.mode, .controlDisabled(lastLimit: 80))
        XCTAssertFalse(settings.heatProtectionEnabled)
        XCTAssertFalse(settings.controlMagSafeLED)
        XCTAssertFalse(backend.operations.contains("release-control"))
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
        try await controller.shutdown()
    }

    func testCorruptOwnershipJournalBlocksInitializationBeforeBackendOpen() async {
        let journalURL = makeOwnershipJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("not-json".utf8).write(to: journalURL)
        let backend = FakeChargeBackend()
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )
        let controller = ChargeController(
            backend: backend,
            monitor: BatteryMonitor(
                batteryInfoProvider: { makeBatteryInfo() },
                runsMonitoringInfrastructure: false
            ),
            settings: settings
        )

        do {
            try await controller.initialize()
            XCTFail("Expected corrupt ownership journal to block initialization")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("소유권 기록"))
        }
        XCTAssertFalse(backend.operations.contains("open"))
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
    }

    func testReleasedControlReconciliationReportsExternalMaintainAsDrift() async throws {
        let expectation = ReconciledChargeExpectation.controlReleased(lastLimit: 80)
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 80)
        )
        try settings.completeBatteryControlRelease(lastLimit: 80)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(expected: expectation, observed: .maintaining(limit: 60))
        )
        XCTAssertTrue(controller.isBatteryControlDisabled)
    }

    func testPendingReleaseRestartNeverReclaimsControlFromObservedMaintain() async throws {
        let backend = FakeChargeBackend()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        let info = makeBatteryInfo(charge: 70)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        try settings.beginBatteryControlRelease(lastLimit: 80)
        backend.failNext("release-control")
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings
        )

        try await controller.initialize()

        if case .externalDrift(let expectation, .unavailable) = controller.mode {
            XCTAssertEqual(expectation, .controlReleasing(lastLimit: 80))
        } else {
            XCTFail("Expected retryable released-control drift")
        }
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
        XCTAssertTrue(settings.batteryControlReleasePending)

        await controller.reconcileExternalState()
        if case .externalDrift(let expectation, .maintaining(limit: 60)) = controller.mode {
            XCTAssertEqual(expectation, .controlReleasing(lastLimit: 80))
        } else {
            XCTFail("Periodic reconciliation must not claim a pending release completed")
        }
        XCTAssertTrue(settings.batteryControlReleasePending)

        await controller.reconcileAfterWake()
        if case .externalDrift(let expectation, .maintaining(limit: 60)) = controller.mode {
            XCTAssertEqual(expectation, .controlReleasing(lastLimit: 80))
        } else {
            XCTFail("Wake reconciliation must preserve pending release ownership")
        }
        XCTAssertTrue(settings.batteryControlReleasePending)

        backend.setControlStatus(nil)
        controller.disableBatteryGuardControl()
        let retrySucceeded = await eventually {
            controller.mode == .controlDisabled(lastLimit: 80)
        }
        XCTAssertTrue(retrySucceeded)
        XCTAssertFalse(settings.batteryControlReleasePending)
        try await controller.shutdown()
    }

    func testWakeAndShutdownKeepReleasedControlReadOnly() async throws {
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 80)
        )
        try settings.completeBatteryControlRelease(lastLimit: 80)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .stopped
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        await controller.reconcileAfterWake()
        try await controller.shutdown()

        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
        XCTAssertFalse(backend.operations.contains("release-control"))
    }
}
