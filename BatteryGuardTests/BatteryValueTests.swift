import XCTest
import Combine
@testable import BatteryGuard

@MainActor
private final class ManualBatteryMonitorClock {
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var now: UInt64 = 0
    private(set) var requestedDeadlines: [UInt64] = []
    private var waiters: [Waiter] = []

    func sleep(until deadline: UInt64) async {
        requestedDeadlines.append(deadline)
        guard deadline > now else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(deadline: deadline, continuation: continuation))
        }
    }

    func advance(to deadline: UInt64) {
        now = max(now, deadline)
        let ready = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class TransitionNotificationFixture: @unchecked Sendable {
    var callback: (@Sendable () -> Void)?
    var cancelledTokens: [Int32] = []
}


final class BatteryValueTests: XCTestCase {
    @MainActor
    func testAppHostedTestCompositionNeverUsesProductionState() {
        XCTAssertTrue(AppRuntime.isRunningTests)
        XCTAssertTrue(BatteryHistory.shared.usesInMemoryStore)
        XCTAssertFalse(BatteryMonitor.shared.usesMonitoringInfrastructure)
        XCTAssertFalse(UserSettings.shared.usesStandardDefaults)
        XCTAssertNil(DiagnosticLog.shared.fileURL)
    }

    func testUnavailableMeasurementsRemainUnavailable() {
        let info = makeBatteryInfo(temperature: nil, amperage: nil, health: nil)
        XCTAssertNil(info.temperature)
        XCTAssertNil(info.amperage)
        XCTAssertNil(info.healthPercent)
    }

    func testBatteryErrorsPreserveActionableContext() {
        let error = BatteryError.commandFailed("battery maintain 80", 42, "permission denied")
        XCTAssertTrue(error.localizedDescription.contains("battery maintain 80"))
        XCTAssertTrue(error.localizedDescription.contains("42"))
        XCTAssertTrue(error.localizedDescription.contains("permission denied"))
    }

    func testAmperageNormalizationPreservesDirectionAndRejectsImplausibleValues() {
        XCTAssertEqual(BatteryMonitor.normalizedAmperage(NSNumber(value: 1_250)), 1_250)
        XCTAssertEqual(BatteryMonitor.normalizedAmperage(NSNumber(value: -900)), -900)
        XCTAssertEqual(
            BatteryMonitor.normalizedAmperage(NSNumber(value: UInt64.max - 999)),
            -1_000
        )
        XCTAssertNil(BatteryMonitor.normalizedAmperage(NSNumber(value: 100_000)))
        XCTAssertEqual(BatteryDisplay.amperage(700), "+700 mA (충전)")
        XCTAssertEqual(BatteryDisplay.amperage(-700), "-700 mA (방전)")
        XCTAssertEqual(BatteryDisplay.amperage(nil), "알 수 없음")
    }

    func testBatteryDictionaryRejectsMissingOrOutOfRangeCharge() {
        XCTAssertNil(BatteryMonitor.parseBatteryInfo([:]))
        XCTAssertNil(BatteryMonitor.parseBatteryInfo(["CurrentCapacity": -1]))
        XCTAssertNil(BatteryMonitor.parseBatteryInfo(["CurrentCapacity": 101]))
    }

    func testMissingMeasurementsStayOptionalInsteadOfBecomingZero() throws {
        let info = try XCTUnwrap(BatteryMonitor.parseBatteryInfo(["CurrentCapacity": 50]))

        XCTAssertNil(info.maxCapacity)
        XCTAssertNil(info.designCapacity)
        XCTAssertNil(info.cycleCount)
        XCTAssertNil(info.voltage)
        XCTAssertNil(info.serialNumber)
    }

    func testTemperatureValidationRejectsNonfiniteAndImplausibleValues() {
        XCTAssertNil(BatteryMonitor.validatedTemperature(.nan))
        XCTAssertNil(BatteryMonitor.validatedTemperature(-273.05))
        XCTAssertNil(BatteryMonitor.validatedTemperature(101))
        XCTAssertEqual(BatteryMonitor.validatedTemperature(37.5), 37.5)

        let rawOne = BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 50,
            "Temperature": 1
        ])
        XCTAssertNil(rawOne?.temperature)
    }

    @MainActor
    func testMonitorPublishesOnlyChangedBatteryInformation() {
        var suppliedInfo = makeBatteryInfo(charge: 70)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { suppliedInfo },
            runsMonitoringInfrastructure: false
        )
        var publishedValues: [BatteryInfo?] = []
        let observation = monitor.$batteryInfo
            .dropFirst()
            .sink { publishedValues.append($0) }

        monitor.refreshBatteryInfo()
        monitor.refreshBatteryInfo()
        suppliedInfo = makeBatteryInfo(charge: 71)
        monitor.refreshBatteryInfo()

        XCTAssertEqual(publishedValues.compactMap { $0?.currentCharge }, [70, 71])
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testPowerNotificationsCoalesceBeforeReadingBatteryState() async {
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(charge: 70)
            },
            runsMonitoringInfrastructure: false
        )
        monitor.startMonitoring()
        readCount = 0

        monitor.scheduleNotificationRefresh()
        monitor.scheduleNotificationRefresh()
        monitor.scheduleNotificationRefresh()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(monitor.batteryInfo?.currentCharge, 70)
        monitor.stopMonitoring()
    }

    @MainActor
    func testRoutineNotificationDoesNotStartPowerTransitionSettlement() async {
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(charge: 70)
            },
            runsMonitoringInfrastructure: false
        )
        monitor.startMonitoring()
        readCount = 0

        monitor.handleBroadPowerSourceNotification()
        monitor.handleBroadPowerSourceNotification()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(readCount, 1)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testBroadNotificationStartsSettlementWhenDedicatedRegistrationIsUnavailable() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()
        source = .ac

        monitor.handleBroadPowerSourceNotification()
        await Task.yield()
        XCTAssertTrue(monitor.hasActivePowerSourceSettlement)
        clock.advance(to: 100)
        await Task.yield()

        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(monitor.batteryInfo?.isPluggedIn, true)
        monitor.stopMonitoring()
        clock.advance(to: 2_000)
        await Task.yield()
    }

    @MainActor
    func testStopMonitoringPreventsQueuedRoutineRefreshFromReading() async {
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo()
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { .ac }
        )
        monitor.startMonitoring()
        readCount = 0

        monitor.scheduleNotificationRefresh()
        monitor.stopMonitoring()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(readCount, 0)
    }

    @MainActor
    func testPowerTransitionSettlesFromTransitionalToChargingSnapshot() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var suppliedInfo = makeBatteryInfo(
            charge: 68,
            isCharging: false,
            isPluggedIn: false,
            amperage: -1_539
        )
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return suppliedInfo
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = .ac
        suppliedInfo = makeBatteryInfo(
            charge: 68,
            isCharging: false,
            isPluggedIn: true,
            amperage: -1_539
        )
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        clock.advance(to: 100)
        await Task.yield()
        XCTAssertEqual(monitor.batteryInfo?.isCharging, false)

        suppliedInfo = makeBatteryInfo(
            charge: 68,
            isCharging: true,
            isPluggedIn: true,
            amperage: 2_100
        )
        clock.advance(to: 500)
        await Task.yield()

        XCTAssertEqual(monitor.batteryInfo?.isCharging, true)
        XCTAssertEqual(monitor.batteryInfo?.amperage, 2_100)
        XCTAssertEqual(readCount, 3)

        monitor.stopMonitoring()
        clock.advance(to: 2_000)
        await Task.yield()
    }

    @MainActor
    func testPowerSignalSettlesWhenSourceSnapshotLagsNotification() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var suppliedInfo = makeBatteryInfo(isPluggedIn: false)
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return suppliedInfo
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        // The dedicated notification can arrive before the IOPS source query
        // changes. The signal must still anchor a settlement immediately.
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        clock.advance(to: 100)
        await Task.yield()
        XCTAssertEqual(readCount, 2)

        source = .ac
        suppliedInfo = makeBatteryInfo(isCharging: true, isPluggedIn: true, amperage: 1_500)
        monitor.handleBroadPowerSourceNotification()
        for deadline: UInt64 in [500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(readCount, 5)
        XCTAssertEqual(monitor.batteryInfo?.isPluggedIn, true)
        XCTAssertEqual(monitor.batteryInfo?.isCharging, true)
        XCTAssertEqual(clock.requestedDeadlines, [100, 500, 1_000, 2_000])
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testSameDirectionPowerNotificationDoesNotRestartOrExtendSettlement() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = .ac
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        monitor.handlePowerSourceTransitionNotification()
        monitor.handlePowerSourceTransitionNotification()
        monitor.scheduleNotificationRefresh()
        monitor.requestPresentationRefresh()

        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(readCount, 5)
        XCTAssertEqual(clock.requestedDeadlines, [100, 500, 1_000, 2_000])
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testReversePowerEdgeCancelsPriorSettlementGeneration() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var suppliedInfo = makeBatteryInfo(isPluggedIn: false)
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return suppliedInfo
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = .ac
        suppliedInfo = makeBatteryInfo(isPluggedIn: true)
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()

        source = .battery
        suppliedInfo = makeBatteryInfo(isPluggedIn: false)
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()

        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(readCount, 5)
        XCTAssertEqual(monitor.batteryInfo?.isPluggedIn, false)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testStopAndRestartInvalidatePriorSettlement() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()
        source = .ac
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()

        monitor.stopMonitoring()
        monitor.startMonitoring()
        let readsAfterRestart = readCount
        clock.advance(to: 2_000)
        await Task.yield()

        XCTAssertEqual(readCount, readsAfterRestart)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testUnknownPowerSourceEstablishesBaselineWithoutSettlement() async {
        var source: BatteryPowerSourceKind?
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source }
        )
        monitor.startMonitoring()
        let readsAfterStart = readCount

        monitor.handlePowerSourceTransitionNotification()
        monitor.handlePowerSourceTransitionNotification()
        XCTAssertEqual(readCount, readsAfterStart + 1)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)

        await Task.yield()
        source = .ac
        monitor.handlePowerSourceTransitionNotification()

        XCTAssertEqual(readCount, readsAfterStart + 2)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testPresentationRefreshCoalescesWithinOneMainRunLoopTurn() async {
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(charge: 70 + readCount)
            },
            runsMonitoringInfrastructure: false
        )

        monitor.requestPresentationRefresh()
        monitor.requestPresentationRefresh()
        monitor.requestPresentationRefresh()
        XCTAssertEqual(readCount, 1)

        await Task.yield()
        monitor.requestPresentationRefresh()
        XCTAssertEqual(readCount, 2)
    }

    @MainActor
    func testTransitionRegistrationFailureKeepsWatchdogAvailable() {
        var registrationAttempts = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo() },
            runsMonitoringInfrastructure: true,
            powerSourceKindProvider: { .ac },
            registersBroadPowerSourceNotifications: false,
            transitionNotificationRegistrar: { _ in
                registrationAttempts += 1
                return nil
            }
        )

        monitor.startMonitoring(interval: 3_600)

        XCTAssertEqual(registrationAttempts, 1)
        XCTAssertTrue(monitor.isWatchdogScheduled)
        monitor.stopMonitoring()
    }

    @MainActor
    func testTransitionDuringObserverRegistrationStartsSettlement() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: true,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            registersBroadPowerSourceNotifications: false,
            transitionNotificationRegistrar: { _ in
                source = .ac
                return 41
            },
            transitionNotificationCanceller: { _ in }
        )

        monitor.startMonitoring(interval: 3_600)
        await Task.yield()

        XCTAssertTrue(monitor.hasActivePowerSourceSettlement)
        clock.advance(to: 100)
        await Task.yield()
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(monitor.batteryInfo?.isPluggedIn, true)

        monitor.stopMonitoring()
        clock.advance(to: 2_000)
        await Task.yield()
    }

    @MainActor
    func testTransitionNotificationTokenIsCancelledAndCallbackCannotOutliveMonitoring() async {
        let clock = ManualBatteryMonitorClock()
        let notification = TransitionNotificationFixture()
        var source: BatteryPowerSourceKind? = .battery
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: true,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            registersBroadPowerSourceNotifications: false,
            transitionNotificationRegistrar: { callback in
                notification.callback = callback
                return 42
            },
            transitionNotificationCanceller: { token in
                notification.cancelledTokens.append(token)
            }
        )
        monitor.startMonitoring(interval: 3_600)

        source = .ac
        notification.callback?()
        await Task.yield()
        XCTAssertTrue(monitor.hasActivePowerSourceSettlement)

        monitor.stopMonitoring()
        XCTAssertEqual(notification.cancelledTokens, [42])
        let readsAfterStop = readCount
        notification.callback?()
        clock.advance(to: 2_000)
        await Task.yield()

        XCTAssertEqual(readCount, readsAfterStop)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }
}
