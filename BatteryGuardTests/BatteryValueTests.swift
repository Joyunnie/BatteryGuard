import XCTest
import Combine
import IOKit.ps
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

@MainActor
private final class ManualNotificationRefreshScheduler {
    private(set) var queuedWork: [DispatchWorkItem] = []

    func schedule(_ work: DispatchWorkItem) {
        queuedWork.append(work)
    }

    func runNext() {
        guard !queuedWork.isEmpty else { return }
        queuedWork.removeFirst().perform()
    }
}


final class BatteryValueTests: XCTestCase {
    func testChargingActivityRequiresAgreementAndPreservesMissingReports() {
        let values: [Bool?] = [nil, false, true]
        for system in values {
            for battery in values {
                let observation = ChargingActivityObservation(systemIsCharging: system, batteryIsCharging: battery)
                let expected: ChargingActivityObservation.State
                if let system, let battery {
                    expected = system == battery ? (battery ? .charging : .notCharging) : .conflicting
                } else {
                    expected = .unavailable
                }
                XCTAssertEqual(observation.state, expected)
                XCTAssertEqual(observation.systemIsCharging, system)
                XCTAssertEqual(observation.batteryIsCharging, battery)
            }
        }
    }

    @MainActor
    func testCurrentDirectionChangeIsRecordedWithoutLoggingEveryCurrentFluctuation() async {
        let log = DiagnosticLog(fileURL: nil, capacity: 100)
        var current = -500
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(isCharging: false, amperage: current) },
            runsMonitoringInfrastructure: false,
            powerSourceSnapshotProvider: { PowerSourceSnapshot(kind: .ac, isCharging: false) },
            diagnostics: log
        )
        monitor.startMonitoring()
        current = -400
        monitor.performWatchdogRefresh()
        current = 100
        monitor.performWatchdogRefresh()
        await log.flushPendingEvents()
        let changes = await log.recentEvents().compactMap(\.powerObservation).filter { $0.phase == .changed }
        XCTAssertEqual(changes.map(\.amperage), [-500, 100])
        XCTAssertTrue(changes.allSatisfy { $0.activity.state == .notCharging })
        monitor.stopMonitoring()
    }

    func testPublicChargingReportSelectsOnlyUniqueInternalBatteryAndStrictBoolean() {
        let internalBattery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsChargingKey: true]
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSIsChargingKey: false]
        XCTAssertEqual(PowerSourceSnapshot.internalBatteryCharging(in: [ups, internalBattery]), true)
        XCTAssertNil(PowerSourceSnapshot.internalBatteryCharging(in: [ups]))
        XCTAssertNil(PowerSourceSnapshot.internalBatteryCharging(in: [internalBattery, internalBattery]))
        for invalid: Any in ["true", NSNumber(value: 2), NSNumber(value: 1.5), NSNumber(value: 1)] {
            XCTAssertNil(PowerSourceSnapshot.internalBatteryCharging(in: [
                [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsChargingKey: invalid]
            ]))
        }
        XCTAssertNil(PowerSourceSnapshot.internalBatteryCharging(in: [[kIOPSTypeKey: kIOPSInternalBatteryType]]))
        XCTAssertEqual(PowerSourceSnapshot.internalBatteryCharging(in: [
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsChargingKey: false]
        ]), false)
    }

    @MainActor
    func testPairedChargingObservationDoesNotReplaceControlMeasurementsOrRepublishIdenticalEvidence() async {
        var source = PowerSourceSnapshot(kind: .ac, isCharging: true)
        var sourceReads = 0
        var batteryReads = 0
        let info = makeBatteryInfo(charge: 67, isCharging: false, amperage: -500)
        let log = DiagnosticLog(fileURL: nil, capacity: 100)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { batteryReads += 1; return info },
            runsMonitoringInfrastructure: false,
            powerSourceSnapshotProvider: { sourceReads += 1; return source },
            diagnostics: log
        )
        var published: [ChargingActivityObservation] = []
        let subscription = monitor.$chargingActivity.dropFirst().sink { published.append($0) }
        monitor.startMonitoring()
        XCTAssertEqual(monitor.chargingActivity.state, .conflicting)
        XCTAssertEqual(monitor.batteryInfo, info)
        XCTAssertEqual(sourceReads, 1)
        XCTAssertEqual(batteryReads, 1)
        for _ in 0..<10 { monitor.performWatchdogRefresh() }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(sourceReads, 11)
        XCTAssertEqual(batteryReads, 11)

        source = .unavailable
        monitor.performWatchdogRefresh()
        XCTAssertNil(monitor.chargingActivity.systemIsCharging)
        XCTAssertEqual(monitor.chargingActivity.batteryIsCharging, false)
        XCTAssertEqual(monitor.chargingActivity.state, .unavailable)
        XCTAssertEqual(monitor.batteryInfo, info)
        // Safety measurement refresh must not read or modify presentation evidence.
        source = PowerSourceSnapshot(kind: .ac, isCharging: false)
        monitor.refreshBatteryInfo()
        XCTAssertEqual(sourceReads, 12)
        XCTAssertNil(monitor.chargingActivity.systemIsCharging)
        monitor.stopMonitoring()
        await log.flushPendingEvents()
        let events = await log.recentEvents()
        XCTAssertEqual(events.compactMap(\.powerObservation).map(\.phase), [.began, .changed, .changed, .ended])
        XCTAssertEqual(Set(events.compactMap(\.operationID)).count, 1)
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
        XCTAssertNil(events.first?.powerObservation?.sampleReadUptimeNanoseconds)
        XCTAssertNotNil(events.last?.powerObservation?.sampleReadUptimeNanoseconds)
        subscription.cancel()
    }

    @MainActor
    func testAppHostedTestCompositionNeverUsesProductionState() {
        XCTAssertTrue(AppRuntime.isRunningTests)
        XCTAssertTrue(BatteryHistory.shared.usesInMemoryStore)
        XCTAssertFalse(BatteryMonitor.shared.usesMonitoringInfrastructure)
        XCTAssertFalse(UserSettings.shared.usesStandardDefaults)
        XCTAssertNil(DiagnosticLog.shared.fileURL)
        XCTAssertNil(DiagnosticLog.powerObservations.fileURL)
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
        XCTAssertNil(info.isCharging)
    }

    func testInvalidChargingFlagRemainsUnknownWithConnectedPower() throws {
        let info = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 70,
            "ExternalConnected": true,
            "IsCharging": "not a boolean"
        ]))
        XCTAssertEqual(info.connectionEvidence, .connected)
        XCTAssertNil(info.isCharging)
        XCTAssertEqual(info.timeToFull, -1)
        XCTAssertEqual(info.timeToEmpty, -1)

        let nonBooleanNumber = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 70,
            "ExternalConnected": true,
            "IsCharging": 2
        ]))
        XCTAssertNil(nonBooleanNumber.isCharging)
        let fractionalNumber = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 70,
            "ExternalConnected": true,
            "IsCharging": NSNumber(value: 1.5)
        ]))
        XCTAssertNil(fractionalNumber.isCharging)
    }

    func testConnectionEvidencePreservesTrueFalseAndMissingSignals() throws {
        let connected = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 50,
            "ExternalConnected": false,
            "ExternalChargeCapable": true,
            "AppleRawExternalConnected": false
        ]))
        let disconnected = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 50,
            "ExternalConnected": false,
            "ExternalChargeCapable": false,
            "AppleRawExternalConnected": false
        ]))
        let uncertain = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 50,
            "ExternalConnected": false
        ]))
        let chargingFallback = try XCTUnwrap(BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 50,
            "IsCharging": true
        ]))

        XCTAssertEqual(connected.connectionEvidence, .connected)
        XCTAssertTrue(connected.isPluggedIn)
        XCTAssertEqual(disconnected.connectionEvidence, .disconnected)
        XCTAssertFalse(disconnected.isPluggedIn)
        XCTAssertEqual(uncertain.connectionEvidence, .uncertain)
        XCTAssertFalse(uncertain.isPluggedIn)
        XCTAssertEqual(chargingFallback.connectionEvidence, .connected)
    }

    func testProvidingSourceConfirmsConnectionWithoutErasingAttachedEvidence() {
        let attached = makeBatteryInfo(
            isPluggedIn: true,
            connectionEvidence: .connected
        )
        let explicitlyDetached = makeBatteryInfo(
            isPluggedIn: false,
            connectionEvidence: .disconnected
        )

        XCTAssertEqual(
            BatteryMonitor.resolvedPowerConnection(info: attached, sourceKind: .battery),
            .connected
        )
        XCTAssertEqual(
            BatteryMonitor.resolvedPowerConnection(info: explicitlyDetached, sourceKind: .ac),
            .connected
        )
        XCTAssertEqual(
            BatteryMonitor.resolvedPowerConnection(info: explicitlyDetached, sourceKind: .battery),
            .disconnected
        )
    }

    func testPresentationEvidenceIsExcludedFromControlMeasurement() {
        let connectedEvidence = makeBatteryInfo(
            isPluggedIn: true,
            connectionEvidence: .connected
        )
        let uncertainEvidence = makeBatteryInfo(
            isPluggedIn: true,
            connectionEvidence: .uncertain
        )

        XCTAssertEqual(
            ChargeController.ControlMeasurement(connectedEvidence),
            ChargeController.ControlMeasurement(uncertainEvidence)
        )
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
    func testInitialReadPublishesStableConnectionObservation() {
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(isPluggedIn: false) },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { .battery }
        )

        monitor.startMonitoring()

        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        monitor.stopMonitoring()
    }

    @MainActor
    func testPreMonitoringPresentationRefreshIsOneBoundedObservation() {
        var batteryReadCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                batteryReadCount += 1
                return makeBatteryInfo(isPluggedIn: false)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return .battery
            }
        )

        monitor.refreshPowerConnectionPresentation()

        XCTAssertEqual(batteryReadCount, 1)
        XCTAssertEqual(sourceReadCount, 1)
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        XCTAssertFalse(monitor.isWatchdogScheduled)
    }

    @MainActor
    func testMissedDisconnectIsRecoveredByWatchdogSettlement() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .ac
        var info = makeBatteryInfo(isPluggedIn: true)
        var batteryReadCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                batteryReadCount += 1
                return info
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = .battery
        info = makeBatteryInfo(isPluggedIn: false)
        monitor.performWatchdogRefresh()
        await Task.yield()

        XCTAssertEqual(monitor.powerConnectionObservation, .transitioning(previous: .connected))
        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        XCTAssertEqual(batteryReadCount, 6)
        XCTAssertEqual(sourceReadCount, 6)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testMissedConnectIsRecoveredByVisibilitySettlement() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var info = makeBatteryInfo(isPluggedIn: false)
        var batteryReadCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                batteryReadCount += 1
                return info
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = .ac
        info = makeBatteryInfo(isPluggedIn: true)
        monitor.requestPresentationRefresh()
        await Task.yield()

        XCTAssertEqual(monitor.powerConnectionObservation, .transitioning(previous: .disconnected))
        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.connected))
        XCTAssertEqual(batteryReadCount, 6)
        XCTAssertEqual(sourceReadCount, 6)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testUnchangedConnectionObservationIsNotRepublished() {
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(isPluggedIn: false) },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { .battery }
        )
        monitor.startMonitoring()
        var publications: [PowerConnectionObservation] = []
        let observation = monitor.$powerConnectionObservation
            .dropFirst()
            .sink { publications.append($0) }

        monitor.refreshBatteryInfo()
        monitor.refreshBatteryInfo()

        XCTAssertTrue(publications.isEmpty)
        withExtendedLifetime(observation) {}
        monitor.stopMonitoring()
    }

    @MainActor
    func testMeasurementOnlyRefreshDoesNotReadOrMutatePresentationSourceState() {
        var source: BatteryPowerSourceKind? = .battery
        var info = makeBatteryInfo(isPluggedIn: false)
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            }
        )
        monitor.startMonitoring()
        sourceReadCount = 0

        source = .ac
        info = makeBatteryInfo(charge: 81, isPluggedIn: true)
        monitor.refreshBatteryInfo()

        XCTAssertEqual(monitor.batteryInfo?.currentCharge, 81)
        XCTAssertEqual(sourceReadCount, 0)
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testPowerNotificationsCoalesceBeforeReadingBatteryState() async {
        let scheduler = ManualNotificationRefreshScheduler()
        var readCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(charge: 70)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return .battery
            },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()
        readCount = 0
        sourceReadCount = 0

        monitor.scheduleNotificationRefresh()
        monitor.scheduleNotificationRefresh()
        monitor.scheduleNotificationRefresh()
        scheduler.runNext()

        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(sourceReadCount, 1)
        XCTAssertEqual(monitor.batteryInfo?.currentCharge, 70)
        monitor.stopMonitoring()
    }

    @MainActor
    func testSteadyWatchdogUsesOnePairedReadWithoutSettlement() {
        var batteryReadCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                batteryReadCount += 1
                return makeBatteryInfo(isPluggedIn: false)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return .battery
            }
        )
        monitor.startMonitoring()
        batteryReadCount = 0
        sourceReadCount = 0

        monitor.performWatchdogRefresh()

        XCTAssertEqual(batteryReadCount, 1)
        XCTAssertEqual(sourceReadCount, 1)
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testRoutineNotificationDoesNotStartPowerTransitionSettlement() async {
        let scheduler = ManualNotificationRefreshScheduler()
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(charge: 70)
            },
            runsMonitoringInfrastructure: false,
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()
        readCount = 0

        monitor.handleBroadPowerSourceNotification()
        monitor.handleBroadPowerSourceNotification()
        scheduler.runNext()

        XCTAssertEqual(readCount, 1)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testBroadNotificationStartsSettlementWhenDedicatedRegistrationIsUnavailable() async {
        let clock = ManualBatteryMonitorClock()
        let scheduler = ManualNotificationRefreshScheduler()
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
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()
        source = .ac

        monitor.handleBroadPowerSourceNotification()
        scheduler.runNext()
        await Task.yield()
        XCTAssertTrue(monitor.hasActivePowerSourceSettlement)
        clock.advance(to: 100)
        await Task.yield()

        XCTAssertEqual(readCount, 3)
        XCTAssertEqual(monitor.batteryInfo?.isPluggedIn, true)
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.connected))
        monitor.stopMonitoring()
        clock.advance(to: 2_000)
        await Task.yield()
    }

    @MainActor
    func testStopMonitoringPreventsQueuedRoutineRefreshFromReading() async {
        let scheduler = ManualNotificationRefreshScheduler()
        var readCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo()
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { .ac },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()
        readCount = 0

        monitor.scheduleNotificationRefresh()
        monitor.stopMonitoring()
        scheduler.runNext()

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
        for _ in 0..<1_000 {
            if clock.requestedDeadlines.contains(100) { break }
            await Task.yield()
        }
        XCTAssertTrue(clock.requestedDeadlines.contains(100))
        clock.advance(to: 100)
        for _ in 0..<1_000 {
            if readCount >= 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(readCount, 2)

        source = .ac
        suppliedInfo = makeBatteryInfo(isCharging: true, isPluggedIn: true, amperage: 1_500)
        monitor.handleBroadPowerSourceNotification()
        for (index, deadline) in [UInt64(500), 1_000, 2_000].enumerated() {
            for _ in 0..<1_000 {
                if clock.requestedDeadlines.contains(deadline) { break }
                await Task.yield()
            }
            XCTAssertTrue(clock.requestedDeadlines.contains(deadline))
            clock.advance(to: deadline)
            for _ in 0..<1_000 {
                if readCount >= index + 3 { break }
                await Task.yield()
            }
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
        let scheduler = ManualNotificationRefreshScheduler()
        var source: BatteryPowerSourceKind? = .battery
        var readCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()

        source = .ac
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        monitor.handlePowerSourceTransitionNotification()
        monitor.handlePowerSourceTransitionNotification()
        monitor.scheduleNotificationRefresh()
        monitor.requestPresentationRefresh()
        monitor.performWatchdogRefresh()

        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(readCount, 5)
        XCTAssertEqual(clock.requestedDeadlines, [100, 500, 1_000, 2_000])
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)

        scheduler.runNext()
        XCTAssertEqual(readCount, 6, "coalesced requests must produce one trailing read")
        XCTAssertEqual(sourceReadCount, 9)
        monitor.stopMonitoring()
    }

    @MainActor
    func testUnresolvedSettlementPublishesUncertainInsteadOfStaleSuccess() async {
        let clock = ManualBatteryMonitorClock()
        var shouldFailRead = false
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                shouldFailRead ? nil : makeBatteryInfo(isPluggedIn: false)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { .battery },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()
        shouldFailRead = true

        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        XCTAssertEqual(
            monitor.powerConnectionObservation,
            .transitioning(previous: .disconnected)
        )

        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(
            monitor.powerConnectionObservation,
            .uncertain(previous: .disconnected)
        )
        monitor.stopMonitoring()
    }

    @MainActor
    func testFailedSourceReadsDuringSettlementDoNotReuseCachedAC() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .ac
        var info = makeBatteryInfo(isPluggedIn: true)
        var batteryReadCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                batteryReadCount += 1
                return info
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            },
            transitionOffsetsNanoseconds: [100, 500, 1_000, 2_000],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = nil
        info = makeBatteryInfo(
            isPluggedIn: false,
            connectionEvidence: .disconnected
        )
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()

        for deadline: UInt64 in [100, 500, 1_000, 2_000] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(monitor.powerConnectionObservation, .uncertain(previous: .connected))
        XCTAssertEqual(batteryReadCount, 5)
        XCTAssertEqual(sourceReadCount, 6)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testFinalUnresolvedSettlementEvidenceOverridesEarlierStableCandidate() async {
        let clock = ManualBatteryMonitorClock()
        var source: BatteryPowerSourceKind? = .battery
        var info = makeBatteryInfo(isPluggedIn: false)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source },
            transitionOffsetsNanoseconds: [100, 500],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) }
        )
        monitor.startMonitoring()

        source = .ac
        info = makeBatteryInfo(isPluggedIn: true)
        monitor.handlePowerSourceTransitionNotification()
        for _ in 0..<1_000 {
            if clock.requestedDeadlines.contains(100) { break }
            await Task.yield()
        }
        XCTAssertTrue(clock.requestedDeadlines.contains(100))
        clock.advance(to: 100)
        for _ in 0..<1_000 {
            if monitor.powerConnectionObservation == .stable(.connected) { break }
            await Task.yield()
        }
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.connected))

        for _ in 0..<1_000 {
            if clock.requestedDeadlines.contains(500) { break }
            await Task.yield()
        }
        XCTAssertTrue(clock.requestedDeadlines.contains(500))

        source = nil
        info = makeBatteryInfo(
            isPluggedIn: false,
            connectionEvidence: .disconnected
        )
        clock.advance(to: 500)
        for _ in 0..<1_000 {
            if !monitor.hasActivePowerSourceSettlement { break }
            await Task.yield()
        }

        XCTAssertEqual(monitor.powerConnectionObservation, .uncertain(previous: .disconnected))
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testFailedSteadySourceReadPublishesUncertainAndRetainsEdgeBaseline() {
        var source: BatteryPowerSourceKind? = .ac
        var info = makeBatteryInfo(isPluggedIn: true)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: { source }
        )
        monitor.startMonitoring()

        source = nil
        info = makeBatteryInfo(
            isPluggedIn: false,
            connectionEvidence: .disconnected
        )
        monitor.performWatchdogRefresh()

        XCTAssertEqual(monitor.powerConnectionObservation, .uncertain(previous: .connected))
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)

        source = .battery
        monitor.performWatchdogRefresh()
        XCTAssertTrue(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testReversePowerEdgeCancelsPriorSettlementGeneration() async {
        let clock = ManualBatteryMonitorClock()
        let scheduler = ManualNotificationRefreshScheduler()
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
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()

        source = .ac
        suppliedInfo = makeBatteryInfo(isPluggedIn: true)
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        monitor.requestPresentationRefresh()

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
        XCTAssertTrue(scheduler.queuedWork.isEmpty)
        XCTAssertEqual(readCount, 5, "the reverse edge must discard the prior trailing read")
        monitor.stopMonitoring()
    }

    @MainActor
    func testBroadOnlyReverseEdgeStartsANewAnchoredGeneration() async {
        let clock = ManualBatteryMonitorClock()
        let scheduler = ManualNotificationRefreshScheduler()
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
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()

        source = .ac
        suppliedInfo = makeBatteryInfo(isPluggedIn: true)
        monitor.handleBroadPowerSourceNotification()
        scheduler.runNext()
        await Task.yield()
        clock.advance(to: 100)
        await Task.yield()
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.connected))

        source = .battery
        suppliedInfo = makeBatteryInfo(isPluggedIn: false)
        monitor.handleBroadPowerSourceNotification()
        clock.advance(to: 500)
        await Task.yield()
        XCTAssertEqual(
            monitor.powerConnectionObservation,
            .transitioning(previous: .connected)
        )

        for deadline: UInt64 in [600, 1_000, 1_500, 2_500] {
            clock.advance(to: deadline)
            await Task.yield()
        }

        XCTAssertEqual(clock.requestedDeadlines, [100, 500, 600, 1_000, 1_500, 2_500])
        XCTAssertEqual(readCount, 7)
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
        monitor.stopMonitoring()
    }

    @MainActor
    func testStopAndRestartInvalidatePriorSettlement() async {
        let clock = ManualBatteryMonitorClock()
        let scheduler = ManualNotificationRefreshScheduler()
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
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            notificationRefreshScheduler: { scheduler.schedule($0) }
        )
        monitor.startMonitoring()
        source = .ac
        monitor.handlePowerSourceTransitionNotification()
        await Task.yield()
        monitor.requestPresentationRefresh()

        monitor.stopMonitoring()
        monitor.startMonitoring()
        let readsAfterRestart = readCount
        clock.advance(to: 2_000)
        await Task.yield()

        XCTAssertEqual(readCount, readsAfterRestart)
        XCTAssertTrue(scheduler.queuedWork.isEmpty)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testUnknownPowerSourceEstablishesBaselineWithoutSettlement() async {
        var source: BatteryPowerSourceKind?
        var readCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(isPluggedIn: source == .ac)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            }
        )
        monitor.startMonitoring()
        let readsAfterStart = readCount

        monitor.handlePowerSourceTransitionNotification()
        monitor.handlePowerSourceTransitionNotification()
        XCTAssertEqual(readCount, readsAfterStart + 1)
        XCTAssertEqual(sourceReadCount, 4)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)

        await Task.yield()
        source = .ac
        monitor.handlePowerSourceTransitionNotification()

        XCTAssertEqual(readCount, readsAfterStart + 2)
        XCTAssertEqual(sourceReadCount, 5)
        XCTAssertFalse(monitor.hasActivePowerSourceSettlement)
    }

    @MainActor
    func testPresentationRefreshCoalescesWithinOneMainRunLoopTurn() async {
        var readCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                readCount += 1
                return makeBatteryInfo(charge: 70 + readCount)
            },
            runsMonitoringInfrastructure: false,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return .battery
            }
        )

        monitor.requestPresentationRefresh()
        monitor.requestPresentationRefresh()
        monitor.requestPresentationRefresh()
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(sourceReadCount, 1)

        await Task.yield()
        monitor.requestPresentationRefresh()
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(sourceReadCount, 2)
    }

    @MainActor
    func testTransitionRegistrationFailureRecoversMissedEdgeThroughWatchdog() async {
        let clock = ManualBatteryMonitorClock()
        var registrationAttempts = 0
        var source: BatteryPowerSourceKind? = .ac
        var info = makeBatteryInfo(isPluggedIn: true)
        var batteryReadCount = 0
        var sourceReadCount = 0
        let monitor = BatteryMonitor(
            batteryInfoProvider: {
                batteryReadCount += 1
                return info
            },
            runsMonitoringInfrastructure: true,
            powerSourceKindProvider: {
                sourceReadCount += 1
                return source
            },
            transitionOffsetsNanoseconds: [100],
            monotonicNow: { clock.now },
            transitionSleepUntil: { deadline in await clock.sleep(until: deadline) },
            registersBroadPowerSourceNotifications: false,
            transitionNotificationRegistrar: { _ in
                registrationAttempts += 1
                return nil
            }
        )

        monitor.startMonitoring(interval: 3_600)

        XCTAssertEqual(registrationAttempts, 1)
        XCTAssertTrue(monitor.isWatchdogScheduled)

        source = .battery
        info = makeBatteryInfo(isPluggedIn: false)
        monitor.performWatchdogRefresh()
        await Task.yield()

        XCTAssertEqual(monitor.powerConnectionObservation, .transitioning(previous: .connected))
        clock.advance(to: 100)
        await Task.yield()
        XCTAssertEqual(monitor.powerConnectionObservation, .stable(.disconnected))
        XCTAssertEqual(batteryReadCount, 4)
        XCTAssertEqual(sourceReadCount, 4)
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
        XCTAssertEqual(readCount, 3)
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
