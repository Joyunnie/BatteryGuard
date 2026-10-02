import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
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

    func testInitializationDoesNotResumeChargingWhenSMCFailsButIOKitIsCool() async throws {
        let backend = FakeChargeBackend()
        backend.failNext("read-temperature")
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70, temperature: 30) },
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
        XCTAssertEqual(controller.mode, .heatBlocked(previous: .maintaining(limit: 80)))
        XCTAssertFalse(controller.safetyTemperatureSnapshot.failures.isEmpty)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
        try await controller.shutdown()
    }

    func testShutdownWaitsForInitializationSafetyDecision() async throws {
        let backend = FakeChargeBackend()
        backend.temperature = 45
        backend.enqueueTemperatureReadDelays([0.2])
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

        let initialization = Task { try await controller.initialize() }
        let temperatureReadStarted = await eventually {
            backend.operations.contains("read-temperature")
        }
        XCTAssertTrue(temperatureReadStarted)

        let shutdown = Task { try await controller.shutdown() }
        try await initialization.value
        try await shutdown.value

        XCTAssertEqual(controller.readiness, .shuttingDown)
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

    func testTransientInitialMaintainFailureUsesReadOnlyVerification() async throws {
        let backend = FakeChargeBackend()
        backend.failNext("maintain", error: BatteryError.commandTimedOut("battery maintain 80"))
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 80) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        try await controller.initialize()

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
        XCTAssertGreaterThanOrEqual(backend.operations.filter { $0 == "read-status" }.count, 2)
    }

    func testFailedInitializationWithoutPreviousModeExposesRetry() async {
        let backend = FakeChargeBackend()
        backend.failNext("open")
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 80) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        do { try await controller.initialize() } catch {}
        XCTAssertNotNil(controller.manualInterventionRecoveryDescription)
        XCTAssertTrue(controller.manualRecoveryRefreshAvailability.isAllowed)
        XCTAssertEqual(controller.manualRecoveryRefreshTitle, "초기화 다시 시도")

        await controller.refreshManualRecoveryStatus()

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testFailedPostMutationInitializationRetriesWithoutAnotherMutation() async {
        let backend = FakeChargeBackend()
        backend.failNext("maintain", error: BatteryError.commandTimedOut("battery maintain 80"))
        let inconsistent = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: nil,
            maintainWorker: .stopped
        )
        backend.setControlStatus(inconsistent)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 80) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        do { try await controller.initialize() } catch {}
        guard case .failed = controller.readiness else {
            return XCTFail("Expected failed readiness")
        }
        XCTAssertTrue(controller.manualRecoveryRefreshAvailability.isAllowed)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )

        await controller.refreshManualRecoveryStatus()

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
    }

    func testFailedWakeRecoveryDoesNotRestartInitialization() async {
        let failedMode = ChargeMode.failed(
            previous: .maintaining(limit: 80),
            message: "wake status timed out",
            disposition: .manualIntervention
        )
        let (controller, backend, _, _) = makeSUT(
            initialReadiness: .failed("wake status timed out"),
            initialMode: failedMode
        )

        await controller.refreshManualRecoveryStatus()

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(backend.operations.contains("open"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
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

}
