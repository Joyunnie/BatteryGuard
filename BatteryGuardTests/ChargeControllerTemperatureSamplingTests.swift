import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
    func testSMCTemperatureSamplingKeepsTheSafetyCadenceIndependentOfIOKit() {
        XCTAssertEqual(ChargeController.smcTemperatureSamplingInterval, 5)
    }

    func testPeriodicSMCSamplesUseStartToStartCadence() async throws {
        let info = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: info,
            smcTemperatureSamplingInterval: 0.05
        )
        backend.enqueueTemperatureReadDelays([0, 0.02, 0.02])

        try await controller.initialize()
        let sampledThreeTimes = await eventually(timeout: 0.25) {
            backend.operations.filter { $0 == "read-temperature" }.count >= 3
        }

        XCTAssertTrue(sampledThreeTimes)
        try await controller.shutdown()
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

    func testSMCTemperatureRiseTriggersHeatProtectionWhenIOKitValueDoesNotChange() async throws {
        let info = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: info
        )
        backend.enqueueTemperatures([30, 45])

        try await controller.initialize()
        let blocked = await eventually {
            if case .heatBlocked = controller.mode { return true }
            return false
        }

        XCTAssertTrue(blocked)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        XCTAssertEqual(controller.safetyTemperatureSnapshot.value, 45)
        try await controller.shutdown()
    }

    func testPresentationRefreshPublishesHotSnapshotThroughHeatProtectionPolicy() async throws {
        let infoSource = TestBatteryInfoSource(makeBatteryInfo(charge: 70, temperature: 30))
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoProvider: { infoSource.read() }
        )
        try await controller.initialize()
        backend.clearOperations()

        infoSource.set(makeBatteryInfo(charge: 70, temperature: 45))
        monitor.requestPresentationRefresh()
        let blocked = await eventually {
            if case .heatBlocked = controller.mode { return true }
            return false
        }

        XCTAssertTrue(blocked)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        try await controller.shutdown()
    }

    func testPartialSMCSampleBlocksOnHighValueAndRemainsDegraded() async throws {
        let info = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: info,
            smcTemperatureSamplingInterval: 0.05
        )
        backend.enqueueTemperatureSamples([
            .complete(30),
            BatteryTemperatureSample(
                maximum: 45,
                failures: ["TB2T: command timed out"]
            )
        ])

        try await controller.initialize()
        let blocked = await eventually {
            if case .heatBlocked = controller.mode {
                return !controller.safetyTemperatureSnapshot.failures.isEmpty
            }
            return false
        }

        XCTAssertTrue(blocked)
        XCTAssertEqual(controller.safetyTemperatureSnapshot.value, 45)
        XCTAssertEqual(controller.safetyTemperatureSnapshot.sources, [.smc])
        XCTAssertEqual(controller.heatProtectionPhase, .blocked)
        XCTAssertTrue(controller.lastError?.contains("TB2T") == true)
        try await controller.shutdown()
    }

    func testSMCFailureRemainsVisibleWhenIOKitTemperatureIsValid() async throws {
        let info = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: info
        )
        backend.enqueueTemperatures([30, nil])

        try await controller.initialize()
        let degraded = await eventually {
            controller.heatProtectionPhase == .degraded &&
                !controller.safetyTemperatureSnapshot.failures.isEmpty
        }
        controller.processBatteryInfo(info)

        XCTAssertTrue(degraded)
        XCTAssertEqual(controller.safetyTemperatureSnapshot.value, 30)
        XCTAssertTrue(controller.lastError?.contains("SMC") == true)
        XCTAssertEqual(controller.heatProtectionPhase, .degraded)
        XCTAssertEqual(monitor.batteryInfo, info)
        try await controller.shutdown()
    }

    func testBlockedHeatProtectionDoesNotRestoreWhileSMCSensorIsDegraded() async throws {
        let coolIOKitInfo = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: coolIOKitInfo
        )
        backend.enqueueTemperatures([45, nil])

        try await controller.initialize()
        let degradedWhileBlocked = await eventually {
            controller.heatProtectionPhase == .blocked &&
                !controller.safetyTemperatureSnapshot.failures.isEmpty
        }

        XCTAssertTrue(degradedWhileBlocked)
        XCTAssertEqual(controller.mode, .heatBlocked(previous: .maintaining(limit: 80)))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
        try await controller.shutdown()
    }

    func testFreshSMCSampleClearsDegradedStateAndRestoresHeatProtectionOnce() async throws {
        let coolIOKitInfo = makeBatteryInfo(charge: 70, temperature: 30)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70,
            batteryInfoOnRead: coolIOKitInfo,
            smcTemperatureSamplingInterval: 0.05
        )
        backend.enqueueTemperatures([45, nil, 37])

        try await controller.initialize()
        let restored = await eventually(timeout: 1) {
            controller.mode == .maintaining(limit: 80) &&
                controller.safetyTemperatureSnapshot.failures.isEmpty
        }

        XCTAssertTrue(restored)
        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
        XCTAssertNil(controller.lastError)
        try await controller.shutdown()
    }

    func testDelayedSMCTemperatureSampleCannotMutateStateAfterShutdown() async throws {
        let backend = FakeChargeBackend()
        backend.enqueueTemperatures([30, 45])
        backend.enqueueTemperatureReadDelays([0, 0.3], ignoringCancellation: true)
        let info = makeBatteryInfo(charge: 70, temperature: 30)
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
        let info = makeBatteryInfo(charge: 70, temperature: 30)
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
        let wakeInfo = makeBatteryInfo(charge: 70, temperature: 30)
        infoSource.set(wakeInfo)
        monitor.batteryInfo = wakeInfo

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
        backend.enqueueTemperatureReadDelays([0, 0.3, 0.1], ignoringCancellation: true)
        let info = makeBatteryInfo(charge: 70, temperature: 30)
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
        let coolInfo = makeBatteryInfo(charge: 70, temperature: 30)
        infoSource.set(coolInfo)
        monitor.batteryInfo = coolInfo
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
        let info = makeBatteryInfo(charge: 70, temperature: 30)
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
