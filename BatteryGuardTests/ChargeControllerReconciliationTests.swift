import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
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

    func testInitializationProcessesCurrentSnapshotAndKeepsHistoryHeartbeat() async throws {
        let heartbeatInterval: TimeInterval = 0.05
        let history = BatteryHistory(
            inMemory: true,
            heartbeatInterval: heartbeatInterval
        )
        let historyReadiness = await history.waitUntilReady()
        XCTAssertEqual(historyReadiness, .ready)
        let info = makeBatteryInfo(charge: 75)
        let (controller, _, monitor, _) = makeSUT(
            charge: 75,
            batteryInfoOnRead: info,
            initialReadiness: .initializing,
            history: history,
            historyHeartbeatInterval: heartbeatInterval
        )

        try await controller.initialize()
        let heartbeatRecorded = await eventually {
            history.fetchLast24Hours().count >= 2
        }

        XCTAssertTrue(heartbeatRecorded)
        XCTAssertEqual(monitor.batteryInfo, info)
        XCTAssertEqual(history.fetchLast24Hours().map(\.chargeLimit), [80, 80])
        try await controller.shutdown()
    }

    func testHistoryHeartbeatIsNotPostponedByUnstoredTemperatureUpdates() async throws {
        let heartbeatInterval: TimeInterval = 0.05
        let history = BatteryHistory(
            inMemory: true,
            heartbeatInterval: heartbeatInterval
        )
        let historyReadiness = await history.waitUntilReady()
        XCTAssertEqual(historyReadiness, .ready)
        let (controller, _, _, _) = makeSUT(
            history: history,
            historyHeartbeatInterval: heartbeatInterval
        )

        controller.processBatteryInfo(makeBatteryInfo(charge: 75, temperature: 30))
        for offset in 1...6 {
            try await Task.sleep(nanoseconds: 20_000_000)
            controller.processBatteryInfo(
                makeBatteryInfo(charge: 75, temperature: 30 + Double(offset) / 10)
            )
        }

        XCTAssertGreaterThanOrEqual(history.fetchLast24Hours().count, 2)
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
        XCTAssertFalse(monitor.isSleepPreventionActive)
    }

    func testLostDischargeOwnershipSurfacesExternalDriftWithoutOverwritingIt() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        XCTAssertTrue(monitor.isSleepPreventionActive)
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
        XCTAssertTrue(monitor.isSleepPreventionActive)
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
        XCTAssertFalse(monitor.isSleepPreventionActive)
    }

    func testUnexpectedDischargeExitReleasesSleepOnlyAfterMaintainRecoverySucceeds() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        XCTAssertTrue(monitor.isSleepPreventionActive)

        backend.setOwnedLongRunningOperation(false)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        controller.processBatteryInfo(makeBatteryInfo(charge: 90))

        let recovered = await eventually { controller.mode == .maintaining(limit: 80) }
        XCTAssertTrue(recovered)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertFalse(monitor.isSleepPreventionActive)
    }

    func testUnexpectedDischargeExitKeepsSleepAssertionWhenMaintainRecoveryFails() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        XCTAssertTrue(monitor.isSleepPreventionActive)

        backend.setOwnedLongRunningOperation(false)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        backend.failNext("maintain")
        controller.processBatteryInfo(makeBatteryInfo(charge: 90))

        let failed = await eventually {
            if case .failed(let previous, _, let disposition) = controller.mode {
                return previous == .maintaining(limit: 80) && disposition == .recoverPrevious
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(monitor.isSleepPreventionActive)
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

}
