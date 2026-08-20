import Foundation
import XCTest
@testable import BatteryGuard

private func makeSleepRequest(
    kind: SystemSleepRequestKind,
    generation: UInt64 = 1,
    deadline: UInt64 = .max
) -> SystemSleepRequest {
    SystemSleepRequest(
        id: UUID(),
        generation: generation,
        kind: kind,
        deadlineUptimeNanoseconds: deadline
    )
}

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
    func testTimeoutDecidesExactlyOnceAndCancelsOwningPreparation() async {
        let decisions = LockedDecisions()
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000,
            timeoutDecision: .reject
        ) { decisions.append($0) }
        let cancellationObserved = LockedFlag()
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                cancellationObserved.setTrue()
            }
            operation.finish(.allow)
        }
        operation.setTask(task)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(cancellationObserved.value)
        XCTAssertTrue(task.isCancelled)
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

    func testInvalidationCancelsOwnerAndResolvesTheRequestedDecisionExactlyOnce() async {
        let decisions = LockedDecisions()
        let operation = SleepAcknowledgedOperation(
            deadlineUptimeNanoseconds: UInt64.max,
            timeoutDecision: .allow
        ) { decisions.append($0) }

        let cancellationObserved = LockedFlag()
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                cancellationObserved.setTrue()
            }
            operation.finish(.allow)
        }
        operation.setTask(task)
        operation.invalidate(resolving: .reject)
        operation.finish(.allow)

        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(decisions.values, [.reject])
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(cancellationObserved.value)
    }
}

@MainActor
final class SystemPowerObserverContractTests: XCTestCase {
    func testVetoableIOKitMessageRejectsWhenPreparationFails() async throws {
        let transport = FakeSystemPowerTransport()
        let observer = SystemPowerObserver(transport: transport)
        var observedRequest: SystemSleepRequest?
        try observer.start(
            willSleep: {
                observedRequest = $0
                return false
            },
            didComplete: { _ in }
        )

        transport.send(messageType: SystemPowerMessage.canSystemSleep, token: 41)
        let resolved = await eventuallyDecision(transport, token: 41)

        XCTAssertEqual(resolved, .reject)
        XCTAssertEqual(observedRequest?.kind, .vetoableIdleSleep)
        XCTAssertEqual(observer.activeSleepRequest?.kind, .vetoableIdleSleep)
        transport.send(messageType: SystemPowerMessage.systemWillNotSleep)
        XCTAssertNil(observer.activeSleepRequest)
    }

    func testForcedSleepAllowsOnlyAfterRunningPreparation() async throws {
        let transport = FakeSystemPowerTransport()
        let observer = SystemPowerObserver(transport: transport)
        let preparationRan = LockedFlag()
        try observer.start(
            willSleep: { _ in
                preparationRan.setTrue()
                return false
            },
            didComplete: { _ in }
        )

        transport.send(messageType: SystemPowerMessage.systemWillSleep, token: 42)
        let resolved = await eventuallyDecision(transport, token: 42)

        XCTAssertTrue(preparationRan.value)
        XCTAssertEqual(resolved, .allow)
        XCTAssertEqual(observer.activeSleepRequest?.kind, .forcedSystemSleep)
        transport.send(messageType: SystemPowerMessage.systemHasPoweredOn)
        XCTAssertNil(observer.activeSleepRequest)
    }

    func testCompletionEventsRemainDistinct() throws {
        let transport = FakeSystemPowerTransport()
        let observer = SystemPowerObserver(transport: transport)
        var completions: [SystemSleepCompletionEvent] = []
        try observer.start(
            willSleep: { _ in true },
            didComplete: { completions.append($0) }
        )

        transport.send(messageType: SystemPowerMessage.systemWillNotSleep)
        transport.send(messageType: SystemPowerMessage.systemHasPoweredOn)

        XCTAssertEqual(completions, [.negotiationCancelled, .poweredOn])
    }

    func testObserverStopCancelsPendingPreparationAndResolvesTokenOnce() async throws {
        let transport = FakeSystemPowerTransport()
        let observer = SystemPowerObserver(transport: transport)
        let cancellationObserved = LockedFlag()
        try observer.start(
            willSleep: { _ in
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    cancellationObserved.setTrue()
                }
                return true
            },
            didComplete: { _ in }
        )

        transport.send(messageType: SystemPowerMessage.canSystemSleep, token: 44)
        await Task.yield()
        observer.stop()
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertTrue(cancellationObserved.value)
        let tokenDecisions = transport.decisions.filter { $0.0 == 44 }
        XCTAssertEqual(tokenDecisions.count, 1)
        XCTAssertEqual(tokenDecisions.first?.1, .reject)
        XCTAssertNil(observer.activeSleepRequest)
    }

    private func eventuallyDecision(
        _ transport: FakeSystemPowerTransport,
        token: Int
    ) async -> SleepAcknowledgementDecision? {
        for _ in 0..<100 {
            if let decision = transport.decisions.first(where: { $0.0 == token })?.1 {
                return decision
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
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
    func testObserverAndControllerUseProductionMessagePathForVerifiedSleepTuple() async throws {
        let transport = FakeSystemPowerTransport()
        let observer = SystemPowerObserver(transport: transport)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .maintaining(limit: 80),
            systemPowerObserver: observer,
            runsSystemPowerObservation: true
        )
        try observer.start(
            willSleep: { request in
                await controller.prepareForSleep(request: request)
            },
            didComplete: { _ in Task { await controller.reconcileAfterWake() } }
        )

        transport.send(messageType: SystemPowerMessage.canSystemSleep, token: 43)
        let resolved = await eventually {
            transport.decisions.contains { $0.0 == 43 }
        }

        XCTAssertTrue(resolved)
        XCTAssertEqual(transport.decisions.first(where: { $0.0 == 43 })?.1, .allow)
        XCTAssertTrue(backend.operations.contains("prepare-system-sleep"))
        XCTAssertTrue(controller.sleepProtectionState.userDescription?.contains("충전을 중지") == true)
    }

    func testVetoableThenForcedSleepSequenceMutatesHardwareOnlyOnce() async throws {
        let transport = FakeSystemPowerTransport()
        let observer = SystemPowerObserver(transport: transport)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .maintaining(limit: 80),
            systemPowerObserver: observer,
            runsSystemPowerObservation: true
        )
        try observer.start(
            willSleep: { request in
                await controller.prepareForSleep(request: request)
            },
            didComplete: { event in
                Task { await controller.handleSystemSleepCompletion(event) }
            }
        )

        transport.send(messageType: SystemPowerMessage.canSystemSleep, token: 45)
        let vetoableResolved = await eventually {
            transport.decisions.contains { $0.0 == 45 }
        }
        XCTAssertTrue(vetoableResolved)
        transport.send(messageType: SystemPowerMessage.systemWillSleep, token: 46)
        let forcedResolved = await eventually {
            transport.decisions.contains { $0.0 == 46 }
        }
        XCTAssertTrue(forcedResolved)

        XCTAssertEqual(
            backend.operations.filter { $0 == "prepare-system-sleep" }.count,
            1
        )
        XCTAssertEqual(observer.activeSleepRequest?.kind, .forcedSystemSleep)
    }

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
        guard case .failed(_, _, .manualRecovery(let context)) = controller.mode else {
            return XCTFail("unverified charging state must fail closed")
        }
        XCTAssertEqual(context.origin, .systemSleep(.forcedSystemSleep))
        XCTAssertEqual(context.target, .restoreMaintain(limit: 80))
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
        guard case .failed(_, _, .manualRecovery) = controller.mode else {
            return XCTFail("expired preparation must fail closed")
        }
    }

    func testForcedSleepFailureWakeRefreshesObservationWithoutAutomaticMaintain() async {
        let (controller, backend, _, _) = makeSUT(initialMode: .maintaining(limit: 80))
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        let prepared = await controller.prepareForSleep(
            request: makeSleepRequest(kind: .forcedSystemSleep)
        )
        XCTAssertFalse(prepared)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        let operationCountBeforeWake = backend.operations.count

        await controller.reconcileAfterWake()

        guard case .failed(_, _, .manualRecovery(let context)) = controller.mode else {
            return XCTFail("forced sleep failure must remain an explicit recovery state")
        }
        XCTAssertEqual(context.target, .restoreMaintain(limit: 80))
        XCTAssertEqual(context.latestObservedState, .chargingDisabled)
        XCTAssertFalse(backend.operations.dropFirst(operationCountBeforeWake).contains("maintain:80"))
    }

    func testManualSleepRecoveryRefreshIsReadOnlyAndKeepsTypedTarget() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-manual-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = DiagnosticLog(
            fileURL: directory.appendingPathComponent("Diagnostics.json"),
            capacity: 10
        )
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: nil
        )
        let failed = ChargeMode.failed(
            previous: .maintaining(limit: 80),
            message: "sleep settlement failed",
            disposition: .manualRecovery(context)
        )
        let (controller, backend, _, _) = makeSUT(
            initialMode: failed,
            diagnostics: diagnostics
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        await controller.refreshManualRecoveryStatus()

        guard case .failed(_, _, .manualRecovery(let updated)) = controller.mode else {
            return XCTFail("read-only refresh must keep the typed failure")
        }
        XCTAssertEqual(updated.latestObservedState, .chargingDisabled)
        XCTAssertFalse(backend.operations.contains("maintain:80"))
        XCTAssertFalse(backend.operations.contains("disable-charging"))
        let event = await diagnostics.recentEvents().last
        XCTAssertEqual(event?.operation, "manual recovery status refreshed")
        XCTAssertEqual(event?.outcome, .drifted)
        XCTAssertNotNil(event?.operationID)
    }

    func testExplicitManualSleepRecoveryRestoresVerifiedMaintain() async {
        let batteryInfo = makeBatteryInfo(charge: 70, isPluggedIn: true, temperature: 30)
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, backend, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
            )
        )
        backend.enqueueControlStatuses([
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            ),
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        ])
        backend.enqueueTemperatures([30, 30])

        controller.restoreMaintainFromManualRecovery()
        let restored = await eventually { controller.mode == .maintaining(limit: 80) }
        XCTAssertTrue(restored)

        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
        XCTAssertEqual(backend.operations.filter { $0 == "read-temperature" }.count, 2)
    }

    func testExplicitManualSleepRecoveryFailsClosedBeforeMutationWhenPreflightIsUnsafe() async {
        let batteryInfo = makeBatteryInfo(charge: 70, isPluggedIn: true, temperature: 30)
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, backend, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
            )
        )
        backend.setOwnedLongRunningOperation(true)

        controller.restoreMaintainFromManualRecovery()
        let completed = await eventually { !controller.isCommandPending }
        XCTAssertTrue(completed)

        guard case .failed(_, _, .manualRecovery) = controller.mode else {
            return XCTFail("unsafe preflight must remain manually recoverable")
        }
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testExplicitManualSleepRecoveryDoesNotMutateWhenIndependentTemperatureFails() async {
        let batteryInfo = makeBatteryInfo(charge: 70, isPluggedIn: true, temperature: 30)
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, backend, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
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
        backend.enqueueTemperatures([nil])

        controller.restoreMaintainFromManualRecovery()
        let completed = await eventually { !controller.isCommandPending }
        XCTAssertTrue(completed)

        guard case .failed(_, _, .manualRecovery) = controller.mode else {
            return XCTFail("sensor failure must keep explicit recovery state")
        }
        XCTAssertFalse(backend.operations.contains("maintain:80"))
        XCTAssertFalse(controller.safetyTemperatureSnapshot.failures.isEmpty)
    }

    func testExplicitManualSleepRecoveryReblocksAfterUnsafeTemperaturePostflight() async {
        let batteryInfo = makeBatteryInfo(charge: 70, isPluggedIn: true, temperature: 30)
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, backend, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
            )
        )
        backend.enqueueControlStatuses([
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            ),
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            ),
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        ])
        backend.enqueueTemperatures([30, 45])

        controller.restoreMaintainFromManualRecovery()
        let completed = await eventually { !controller.isCommandPending }
        XCTAssertTrue(completed)

        guard case .failed(_, _, .manualRecovery) = controller.mode else {
            return XCTFail("unsafe postflight must remain manually recoverable")
        }
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("disable-charging"))
    }

    func testExplicitManualSleepRecoveryBlocksDuplicateClicks() async {
        let batteryInfo = makeBatteryInfo(charge: 70, isPluggedIn: true, temperature: 30)
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, backend, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
            )
        )
        backend.maintainDelay = 0.1
        backend.enqueueControlStatuses([
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        ])
        backend.enqueueTemperatures([30, 30])

        controller.restoreMaintainFromManualRecovery()
        controller.restoreMaintainFromManualRecovery()

        let restored = await eventually { controller.mode == .maintaining(limit: 80) }
        XCTAssertTrue(restored)
        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
    }

    func testExplicitManualSleepRecoveryKeepsLatestObservedDriftAfterPostflight() async {
        let batteryInfo = makeBatteryInfo(charge: 70, isPluggedIn: true, temperature: 30)
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, backend, _, _) = makeSUT(
            batteryInfoOnRead: batteryInfo,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
            )
        )
        backend.enqueueControlStatuses([
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            ),
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            ),
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        ])
        backend.enqueueTemperatures([30, 30])

        controller.restoreMaintainFromManualRecovery()
        let completed = await eventually { !controller.isCommandPending }
        XCTAssertTrue(completed)

        guard case .failed(_, _, .manualRecovery(let updated)) = controller.mode else {
            return XCTFail("postflight drift must remain explicit recovery")
        }
        XCTAssertEqual(updated.latestObservedState, .chargingDisabled)
        XCTAssertEqual(backend.operations.filter { $0 == "maintain:80" }.count, 1)
        XCTAssertFalse(backend.operations.contains("disable-charging"))
    }

    func testManualRecoveryPresentationKeepsPhysicalPowerAndControlFailureDistinct() {
        let context = ManualRecoveryContext(
            origin: .systemSleep(.forcedSystemSleep),
            target: .restoreMaintain(limit: 80),
            latestObservedState: .chargingDisabled
        )
        let (controller, _, monitor, _) = makeSUT(
            isPluggedIn: true,
            initialMode: .failed(
                previous: .maintaining(limit: 80),
                message: "sleep settlement failed",
                disposition: .manualRecovery(context)
            )
        )

        XCTAssertEqual(controller.primaryChargeStatusTitle, "전원 연결됨 · 충전 제어 복구 필요")
        XCTAssertEqual(controller.manualRecoveryObservedDescription, "최근 확인 상태: 충전 비활성")
        XCTAssertTrue(controller.explicitMaintainRecoveryAvailability.isAllowed)

        monitor.batteryInfo = makeBatteryInfo(
            charge: 70,
            isPluggedIn: false,
            temperature: 30
        )
        XCTAssertEqual(controller.primaryChargeStatusTitle, "충전 제어 복구 필요")
        XCTAssertFalse(controller.explicitMaintainRecoveryAvailability.isAllowed)
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

    func testDuplicateSleepRequestSharesOneSafetyTransition() async {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .toppingUp(returnLimit: 80)
        )
        backend.setOwnedLongRunningOperation(true)
        backend.setCancelLongRunningDelay(0.05, ignoringCancellation: true)

        let request = makeSleepRequest(kind: .vetoableIdleSleep)
        async let first = controller.prepareForSleep(request: request)
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second = controller.prepareForSleep(request: request)
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
        observer.activeSleepRequest = makeSleepRequest(kind: .forcedSystemSleep)
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
        XCTAssertNil(observer.activeSleepRequest)
    }

    func testDisabledSleepStrategyPreservesMaintainDuringIOKitNegotiationShutdown() async throws {
        let observer = FakeSystemPowerObserver()
        observer.activeSleepRequest = makeSleepRequest(kind: .forcedSystemSleep)
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
        observer.activeSleepRequest = makeSleepRequest(kind: .forcedSystemSleep)
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

    func testWakeDoesNotResumeMaintainWhenSMCFailsButIOKitIsCool() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            initialMode: .sleepProtected(previous: previous, charge: 70)
        )
        backend.failNext("read-temperature")
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        await controller.reconcileAfterWake()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: previous))
        XCTAssertFalse(controller.safetyTemperatureSnapshot.failures.isEmpty)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
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
