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

}
