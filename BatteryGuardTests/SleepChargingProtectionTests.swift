import XCTest
@testable import BatteryGuard

final class SleepChargingPolicyTests: XCTestCase {
    func testStableOwnedModesRequireChargingOff() {
        let modes: [ChargeMode] = [
            .maintaining(limit: 80),
            .toppingUp(returnLimit: 80),
            .discharging(target: 60, returnLimit: 80)
        ]

        for mode in modes {
            XCTAssertEqual(
                SleepChargingPolicy.preparationAction(
                    strategy: .pauseOnSleep,
                    ownsBatteryControl: true,
                    mode: mode,
                    effectiveLimit: 80
                ),
                .stopCharging(previous: mode.restorableMode ?? .maintaining(limit: 80))
            )
        }
    }

    func testAlreadyProtectedModeRequiresReadOnlyVerification() {
        let modes: [ChargeMode] = [
            .sleepProtected(previous: .maintaining(limit: 80), charge: 70),
            .heatBlocked(previous: .maintaining(limit: 80))
        ]
        for mode in modes {
            XCTAssertEqual(
                SleepChargingPolicy.preparationAction(
                    strategy: .pauseOnSleep,
                    ownsBatteryControl: true,
                    mode: mode,
                    effectiveLimit: 80
                ),
                .verifyAlreadyProtected
            )
        }
    }

    func testOwnedTransitionIsPreemptedButControlReleaseIsNotReclaimed() {
        XCTAssertEqual(
            SleepChargingPolicy.preparationAction(
                strategy: .pauseOnSleep,
                ownsBatteryControl: true,
                mode: .transitioning(.startingTopUp(returnLimit: 80)),
                effectiveLimit: 80
            ),
            .stopCharging(previous: .maintaining(limit: 80))
        )
        XCTAssertEqual(
            SleepChargingPolicy.preparationAction(
                strategy: .pauseOnSleep,
                ownsBatteryControl: true,
                mode: .transitioning(.releasingControl(previous: .maintaining(limit: 80))),
                effectiveLimit: 80
            ),
            .rejectWithoutMutation
        )
    }

    func testDisabledMonitoringAndUncertainStatesRemainUntouched() {
        let externalDrift = ChargeMode.externalDrift(
            expected: .maintaining(limit: 80),
            observed: .maintaining(limit: 60)
        )
        let manualFailure = ChargeMode.failed(
            previous: .maintaining(limit: 80),
            message: "uncertain",
            disposition: .manualIntervention
        )
        let cases: [(SleepChargingStrategy, Bool, ChargeMode)] = [
            (.disabled, true, .maintaining(limit: 80)),
            (.pauseOnSleep, false, .controlDisabled(lastLimit: 80)),
            (.pauseOnSleep, true, externalDrift),
            (.pauseOnSleep, true, manualFailure),
            (.pauseOnSleep, true, .idle)
        ]

        for (strategy, ownsControl, mode) in cases {
            XCTAssertEqual(
                SleepChargingPolicy.preparationAction(
                    strategy: strategy,
                    ownsBatteryControl: ownsControl,
                    mode: mode,
                    effectiveLimit: 80
                ),
                strategy == .disabled || !ownsControl
                    ? .allowWithoutMutation
                    : .rejectWithoutMutation
            )
        }
    }
}

final class SleepAcknowledgedOperationTests: XCTestCase {
    func testTimeoutDecidesExactlyOnceWithoutCancellingSafetyCleanup() async {
        let decisions = LockedDecisions()
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000,
            timeoutDecision: .reject
        ) { decisions.append($0) }
        let cleanupFinished = LockedFlag()
        let task = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            cleanupFinished.setTrue()
            operation.finish(.allow)
        }
        operation.setTask(task)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(cleanupFinished.value)
        XCTAssertFalse(task.isCancelled)
        XCTAssertEqual(decisions.values, [.reject])
    }

    func testCompletedPreparationBeatsTimeout() async {
        let decisions = LockedDecisions()
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            timeoutDecision: .reject
        ) { decisions.append($0) }
        operation.finish(.allow)

        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(decisions.values, [.allow])
    }

    func testInvalidationResolvesTheRequestedDecisionExactlyOnce() {
        let decisions = LockedDecisions()
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: UInt64.max,
            timeoutDecision: .allow
        ) { decisions.append($0) }

        operation.invalidate(resolving: .reject)
        operation.finish(.allow)

        XCTAssertEqual(decisions.values, [.reject])
    }
}

private final class LockedDecisions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SleepAcknowledgementDecision] = []
    var values: [SleepAcknowledgementDecision] { lock.withLock { storage } }
    func append(_ decision: SleepAcknowledgementDecision) {
        lock.withLock { storage.append(decision) }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func setTrue() { lock.withLock { storage = true } }
}

@MainActor
extension ChargeControllerSafetyTests {
    func testPauseStrategyStopsChargingAndWakeRestoresVerifiedMaintain() async {
        let (controller, backend, _, _) = makeSUT(
            charge: 67,
            initialMode: .toppingUp(returnLimit: 80)
        )
        backend.setOwnedLongRunningOperation(true)

        let prepared = await controller.prepareForSleep()

        XCTAssertTrue(prepared)
        XCTAssertEqual(controller.mode, .sleepProtected(previous: .toppingUp(returnLimit: 80), charge: 67))
        XCTAssertEqual(controller.sleepProtectionState, .pausedForSleep(charge: 67))
        XCTAssertTrue(backend.operations.contains("prepare-system-sleep"))

        await controller.reconcileAfterWake()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
    }

    func testSleepProtectionRejectsUnverifiedDisabledTuple() async {
        let (controller, backend, _, _) = makeSUT(initialMode: .maintaining(limit: 80))
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        let prepared = await controller.prepareForSleep()

        XCTAssertFalse(prepared)
        guard case .failed(_, _, .manualIntervention) = controller.mode else {
            return XCTFail("unverified charging state must fail closed")
        }
        guard case .unavailable = controller.sleepProtectionState else {
            return XCTFail("sleep protection failure must be visible")
        }
    }

    func testSleepPreparationFailsBeforeAcknowledgementReserveExpires() async {
        let (controller, backend, _, _) = makeSUT(initialMode: .maintaining(limit: 80))
        backend.setCancelLongRunningDelay(0.03, ignoringCancellation: true)
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000

        let prepared = await controller.prepareForSleep(
            deadlineUptimeNanoseconds: deadline
        )

        XCTAssertFalse(prepared)
        guard case .failed(_, _, .manualIntervention) = controller.mode else {
            return XCTFail("expired preparation must fail closed")
        }
    }

    func testPreparingDischargeForSleepReleasesItsSleepAssertionAfterVerification() async {
        let assertionReleased = LockedFlag()
        let (controller, _, _, _) = makeSUT(
            initialMode: .discharging(target: 60, returnLimit: 80),
            allowSleepHandler: { assertionReleased.setTrue() }
        )

        let prepared = await controller.prepareForSleep()

        XCTAssertTrue(prepared)
        XCTAssertTrue(assertionReleased.value)
        XCTAssertEqual(
            controller.mode,
            .sleepProtected(previous: .discharging(target: 60, returnLimit: 80), charge: 80)
        )
    }

    func testHeatBlockSurvivesSleepPreparationAndImmediateShutdown() async throws {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .heatBlocked(previous: previous)
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        let prepared = await controller.prepareForSleep()
        XCTAssertTrue(prepared)
        XCTAssertEqual(controller.mode, .heatBlocked(previous: previous))

        try await controller.shutdown()

        XCTAssertFalse(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("disable-charging"))
    }

    func testConcurrentSleepRequestsShareOneSafetyTransition() async {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .toppingUp(returnLimit: 80)
        )
        backend.setOwnedLongRunningOperation(true)
        backend.setCancelLongRunningDelay(0.05, ignoringCancellation: true)

        async let first = controller.prepareForSleep()
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second = controller.prepareForSleep()
        let results = await [first, second]

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(backend.operations.filter { $0 == "prepare-system-sleep" }.count, 1)
    }

    func testWakeWaitsForTimedOutSleepCleanupBeforeRestoringMaintain() async {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .toppingUp(returnLimit: 80)
        )
        backend.setOwnedLongRunningOperation(true)
        backend.setCancelLongRunningDelay(0.08, ignoringCancellation: true)

        let sleepTask = Task { await controller.prepareForSleep() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await controller.reconcileAfterWake()
        _ = await sleepTask.value

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        let operations = backend.operations
        guard let disableIndex = operations.firstIndex(of: "prepare-system-sleep"),
              let maintainIndex = operations.lastIndex(of: "maintain:80") else {
            return XCTFail("sleep cleanup and wake restoration must both run")
        }
        XCTAssertLessThan(disableIndex, maintainIndex)
    }

    func testShutdownClaimsLifecycleBeforeWaitingForSleepCleanup() async throws {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .toppingUp(returnLimit: 80)
        )
        backend.setCancelLongRunningDelay(0.08, ignoringCancellation: true)

        let sleepTask = Task { await controller.prepareForSleep() }
        let preparationStarted = await eventually {
            backend.operations.contains("prepare-system-sleep")
        }
        XCTAssertTrue(preparationStarted)
        let shutdownTask = Task { try await controller.shutdown() }
        await Task.yield()

        await controller.reconcileAfterWake()
        do {
            try await controller.shutdown()
            XCTFail("duplicate shutdown must be rejected while cleanup is owned")
        } catch {
            // Expected: the first shutdown owns the lifecycle before its first await.
        }

        _ = await sleepTask.value
        try await shutdownTask.value
        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
    }

    func testForcedSleepPendingDuringShutdownKeepsChargingDisabled() async throws {
        let observer = FakeSystemPowerObserver()
        observer.requiresChargingDisabledForSleepTransition = true
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .sleepProtected(previous: previous, charge: 70),
            systemPowerObserver: observer
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        let prepared = await controller.prepareForSleep()
        XCTAssertTrue(prepared)

        try await controller.shutdown()

        XCTAssertFalse(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        XCTAssertFalse(observer.requiresChargingDisabledForSleepTransition)
    }

    func testDisabledSleepStrategyPreservesMaintainDuringIOKitNegotiationShutdown() async throws {
        let observer = FakeSystemPowerObserver()
        observer.requiresChargingDisabledForSleepTransition = true
        let (controller, backend, _, _) = makeSUT(
            initialMode: .maintaining(limit: 80),
            sleepChargingStrategy: .disabled,
            systemPowerObserver: observer
        )

        let prepared = await controller.prepareForSleep()
        XCTAssertTrue(prepared)
        try await controller.shutdown()

        XCTAssertFalse(backend.operations.contains("disable-charging"))
    }

    func testRejectedDriftIsNotOverwrittenDuringIOKitNegotiationShutdown() async throws {
        let observer = FakeSystemPowerObserver()
        observer.requiresChargingDisabledForSleepTransition = true
        let drift = ChargeMode.externalDrift(
            expected: .maintaining(limit: 80),
            observed: .maintaining(limit: 60)
        )
        let (controller, backend, _, _) = makeSUT(
            initialMode: drift,
            systemPowerObserver: observer
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 660, target: 60)
            )
        )

        let prepared = await controller.prepareForSleep()
        XCTAssertFalse(prepared)
        try await controller.shutdown()

        XCTAssertFalse(backend.operations.contains("disable-charging"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testExternalDriftRejectsVoluntarySleepWithoutMutatingHardware() async {
        let drift = ChargeMode.externalDrift(
            expected: .maintaining(limit: 80),
            observed: .maintaining(limit: 60)
        )
        let (controller, backend, _, _) = makeSUT(initialMode: drift)

        let prepared = await controller.prepareForSleep()

        XCTAssertFalse(prepared)
        XCTAssertEqual(controller.mode, drift)
        XCTAssertFalse(backend.operations.contains("prepare-system-sleep"))

        await controller.reconcileAfterWake()

        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testWakeObservesNewTerminalDriftBeforeRestoringAnything() async {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .maintaining(limit: 80),
            sleepChargingStrategy: .disabled
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 600, target: 60)
            )
        )

        await controller.reconcileAfterWake()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(
                expected: .maintaining(limit: 80),
                observed: .maintaining(limit: 60)
            )
        )
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testWakeDoesNotRestoreMaintainWhenSleepProtectedTupleDrifted() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .sleepProtected(previous: previous, charge: 70)
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 601, target: 60)
            )
        )

        await controller.reconcileAfterWake()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(
                expected: .sleepProtected(previous: previous),
                observed: .maintaining(limit: 60)
            )
        )
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testHotWakePreservesTerminalDriftBeforeApplyingHeatProtection() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            initialMode: .sleepProtected(previous: previous, charge: 70)
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 602, target: 60)
            )
        )

        await controller.reconcileAfterWake()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(
                expected: .sleepProtected(previous: previous),
                observed: .maintaining(limit: 60)
            )
        )
        XCTAssertFalse(backend.operations.contains("disable-charging"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testHotWakeNeverResumesInterruptedTopUp() async {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 70,
            initialMode: .sleepProtected(previous: .toppingUp(returnLimit: 80), charge: 70)
        )
        backend.temperature = 45
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        await controller.reconcileAfterWake()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: .maintaining(limit: 80)))
        XCTAssertFalse(backend.operations.contains("top-up:100"))
    }

    func testDisabledStrategyDoesNotMutateBatteryState() async {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .maintaining(limit: 80),
            sleepChargingStrategy: .disabled
        )

        let prepared = await controller.prepareForSleep()

        XCTAssertTrue(prepared)
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(backend.operations.contains("prepare-system-sleep"))
    }

    func testObserverRegistrationFailureDegradesOnlySleepProtection() async throws {
        let observer = FakeSystemPowerObserver()
        observer.startError = BatteryError.unsupported("observer unavailable")
        let batteryInfo = makeBatteryInfo(charge: 70)
        let (controller, _, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialReadiness: .initializing,
            initialMode: .idle,
            systemPowerObserver: observer,
            runsSystemPowerObservation: true
        )

        try await controller.initialize()

        XCTAssertEqual(controller.readiness, .ready)
        guard case .unavailable(let message) = controller.sleepProtectionState else {
            return XCTFail("observer failure must degrade only sleep protection")
        }
        XCTAssertTrue(message.contains("observer unavailable"))
    }
}
