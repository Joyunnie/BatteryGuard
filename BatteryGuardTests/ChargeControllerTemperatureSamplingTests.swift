import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
    func testSMCTemperatureSamplingKeepsTheSafetyCadenceIndependentOfIOKit() {
        XCTAssertEqual(ChargeController.smcTemperatureSamplingInterval, 5)
    }

    func testSafetyTemperatureUsesIOKitWhileHeatProtectionIsDisabled() {
        let (controller, _, _, _) = makeSUT(heatProtectionEnabled: false, temperature: 31.5)

        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: 31.5))

        XCTAssertEqual(controller.safetyTemperatureSnapshot.value, 31.5)
        XCTAssertEqual(controller.safetyTemperatureSnapshot.sources, [.ioKit])
        XCTAssertEqual(controller.safetyTemperatureSnapshot.freshness, .fresh)
    }

    func testMissingCurrentTemperatureKeepsOnlyAStaleDisplayValue() {
        let (controller, _, _, _) = makeSUT(heatProtectionEnabled: false, temperature: 31.5)
        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: 31.5))

        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: nil))

        XCTAssertEqual(controller.safetyTemperatureSnapshot.value, 31.5)
        XCTAssertEqual(controller.safetyTemperatureSnapshot.freshness, .stale)
        XCTAssertTrue(controller.safetyTemperatureSnapshot.displayValue.contains("오래됨"))
    }

    func testSafetyTemperatureAttributesMaximumToTheHotterSensor() async throws {
        let info = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: info
        )
        backend.temperature = 40

        try await controller.initialize()
        let sampled = await eventually {
            controller.safetyTemperatureSnapshot.value == 40
        }

        XCTAssertTrue(sampled)
        XCTAssertEqual(controller.safetyTemperatureSnapshot.sources, [.smc])
        try await controller.shutdown()
    }

    func testDelayedSMCTemperatureSampleCannotMutateStateAfterShutdown() async throws {
        let backend = FakeChargeBackend()
        backend.enqueueTemperatures([30, 45])
        backend.enqueueTemperatureReadDelays([0, 0.3], ignoringCancellation: true)
        let info = makeBatteryInfo(charge: 70, temperature: nil)
        let infoSource = TestBatteryInfoSource(info)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { infoSource.read() },
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
            settings: settings
        )

        try await controller.initialize()
        let delayedSampleStarted = await eventually {
            backend.operations.filter { $0 == "read-temperature" }.count == 2
        }
        XCTAssertTrue(delayedSampleStarted)
        infoSource.set(nil)
        monitor.batteryInfo = nil

        try await controller.shutdown()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertFalse(backend.operations.contains("disable-charging"))
    }

    func testDelayedPreWakeSMCTemperatureSampleCannotOverrideWakeResult() async throws {
        let backend = FakeChargeBackend()
        backend.enqueueTemperatures([30, 45, 30])
        backend.enqueueTemperatureReadDelays([0, 0.3, 0], ignoringCancellation: true)
        let info = makeBatteryInfo(charge: 70, temperature: nil)
        let infoSource = TestBatteryInfoSource(info)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { infoSource.read() },
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
            settings: settings
        )

        try await controller.initialize()
        let delayedSampleStarted = await eventually {
            backend.operations.filter { $0 == "read-temperature" }.count == 2
        }
        XCTAssertTrue(delayedSampleStarted)
        infoSource.set(nil)
        monitor.batteryInfo = nil

        await controller.reconcileAfterWake()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertFalse(backend.operations.contains("disable-charging"))
        try await controller.shutdown()
    }

    func testHeatToggleIgnoresDelayedSampleFromPreviousEnableGeneration() async throws {
        let backend = FakeChargeBackend()
        backend.enqueueTemperatures([30, 45, 30])
        backend.enqueueTemperatureReadDelays([0, 0.3, 0], ignoringCancellation: true)
        let info = makeBatteryInfo(charge: 70, temperature: nil)
        let infoSource = TestBatteryInfoSource(info)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { infoSource.read() },
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
            settings: settings
        )

        try await controller.initialize()
        let delayedSampleStarted = await eventually {
            backend.operations.filter { $0 == "read-temperature" }.count == 2
        }
        XCTAssertTrue(delayedSampleStarted)
        infoSource.set(nil)
        monitor.batteryInfo = nil

        controller.setHeatProtectionEnabled(false)
        controller.setHeatProtectionEnabled(true)
        let replacementSampleCompleted = await eventually {
            backend.operations.filter { $0 == "read-temperature" }.count >= 3
                && controller.mode == .maintaining(limit: 80)
        }
        XCTAssertTrue(replacementSampleCompleted)
        let operationsAfterReplacement = backend.operations
        let chargingWasBlockedAt = try XCTUnwrap(
            operationsAfterReplacement.firstIndex(of: "disable-charging")
        )
        let replacementSampleStartedAt = try XCTUnwrap(
            operationsAfterReplacement.lastIndex(of: "read-temperature")
        )
        XCTAssertLessThan(chargingWasBlockedAt, replacementSampleStartedAt)
        let disableCount = backend.operations.filter { $0 == "disable-charging" }.count
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(
            backend.operations.filter { $0 == "disable-charging" }.count,
            disableCount
        )
        try await controller.shutdown()
    }

    func testControlReleaseInvalidatesDelayedSMCTemperatureSample() async throws {
        let backend = FakeChargeBackend()
        backend.enqueueTemperatures([30, 45])
        backend.enqueueTemperatureReadDelays([0, 0.3], ignoringCancellation: true)
        let info = makeBatteryInfo(charge: 70, temperature: nil)
        let infoSource = TestBatteryInfoSource(info)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { infoSource.read() },
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
            settings: settings
        )

        try await controller.initialize()
        let delayedSampleStarted = await eventually {
            backend.operations.filter { $0 == "read-temperature" }.count == 2
        }
        XCTAssertTrue(delayedSampleStarted)
        infoSource.set(nil)
        monitor.batteryInfo = nil

        controller.disableBatteryGuardControl()
        let released = await eventually {
            controller.mode == .controlDisabled(lastLimit: 80)
        }
        XCTAssertTrue(released)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(settings.batteryControlOwnership, .system(lastLimit: 80))
        XCTAssertFalse(backend.operations.contains("disable-charging"))
        try await controller.shutdown()
    }
}
