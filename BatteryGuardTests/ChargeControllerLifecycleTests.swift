import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
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

}
