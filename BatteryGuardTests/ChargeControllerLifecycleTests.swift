import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
    func testShutdownInvalidatesWakeTemperatureReadBeforeHardwareMutation() async throws {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 80
        )
        backend.enqueueTemperatures([30])
        backend.enqueueTemperatureReadDelays([0.3], ignoringCancellation: true)

        let wake = Task { await controller.reconcileAfterWake() }
        let temperatureReadStarted = await eventually {
            backend.operations.contains("read-temperature")
        }
        XCTAssertTrue(temperatureReadStarted)

        try await controller.shutdown()
        await wake.value

        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertFalse(backend.operations.contains("maintain:80"))
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

    func testWakeInvalidatesStaleReconciliationAndPreservesObservedDrift() async {
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

        XCTAssertEqual(
            controller.mode,
            .externalDrift(
                expected: .maintaining(limit: 80),
                observed: .maintaining(limit: 60)
            )
        )
        XCTAssertTrue(controller.hasExternalControlDrift)
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

    func testDischargeDoesNotMutateHardwareWhenSleepAssertionCannotBeAcquired() async {
        let (controller, backend, monitor, settings) = makeSUT(
            charge: 90,
            preventSleepHandler: { _ in false }
        )
        settings.chargeLimit = 80

        controller.startDischarge()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(backend.operations.contains("discharge:80"))
        XCTAssertFalse(monitor.isSleepPreventionActive)
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertTrue(controller.lastError?.contains("Discharge를 시작하지 않았습니다") == true)
    }

    func testFailedDischargeStartReleasesSleepAssertionAfterMaintainRecovery() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        backend.failNext("discharge")

        controller.startDischarge()
        let finished = await eventually { !controller.isCommandPending }

        XCTAssertTrue(finished)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertFalse(monitor.isSleepPreventionActive)
    }

    func testFailedDischargeCompensationRetainsSleepAssertionForManualRecovery() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        backend.failNext("discharge")
        backend.failNext("maintain")

        controller.startDischarge()
        let finished = await eventually { !controller.isCommandPending }

        XCTAssertTrue(finished)
        XCTAssertTrue(monitor.isSleepPreventionActive)
        guard case .failed(_, _, .manualIntervention) = controller.mode else {
            return XCTFail("Expected manual-intervention failure")
        }
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

    func testWakeAwaitsAnInFlightMaintainCompletionBeforeReconciling() async {
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

        XCTAssertEqual(controller.mode, .maintaining(limit: 60))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertFalse(controller.isCommandPending)
        XCTAssertEqual(backend.operations.last(where: { $0.hasPrefix("maintain:") }), "maintain:60")
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


        do {
            try await controller.shutdown()
            XCTFail("Manual intervention must not be auto-recovered on retry")
        } catch {
            XCTAssertEqual(controller.readiness, .ready)
        }
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

        do {
            try await controller.shutdown()
            XCTFail("Manual intervention must retain the sleep assertion")
        } catch {
            XCTAssertTrue(monitor.isSleepPreventionActive)
        }
    }

    func testShutdownCancellationFailureStopsBeforeAnyRecoveryMutation() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        backend.clearOperations()
        backend.failNext("request-cancellation")

        do {
            try await controller.shutdown()
            XCTFail("Expected cancellation failure")
        } catch {
            XCTAssertEqual(backend.operations, ["request-cancellation"])
            XCTAssertTrue(monitor.isSleepPreventionActive)
            XCTAssertTrue(controller.isReady)
            guard case .failed(_, _, .manualIntervention) = controller.mode else {
                return XCTFail("Expected manual intervention after uncertain cancellation")
            }
        }
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
