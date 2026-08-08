import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
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
        backend.temperature = nil
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
        } catch let error as BatteryError {
            guard case .ownershipPersistenceFailed(let message) = error else {
                return XCTFail("Expected typed ownership persistence failure, got \(error)")
            }
            XCTAssertTrue(message.contains("소유권 기록"))
        } catch {
            XCTFail("Expected BatteryError, got \(error)")
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
