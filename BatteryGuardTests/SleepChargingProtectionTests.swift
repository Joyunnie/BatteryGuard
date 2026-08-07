import XCTest
import Darwin
@testable import BatteryGuard

final class SleepChargingPolicyTests: XCTestCase {
    func testAcquireRequiresOwnedMaintainBelowLimitOnAC() {
        XCTAssertEqual(
            SleepChargingPolicy.awakeAction(
                strategy: .finishChargingThenSleep,
                ownsBatteryControl: true,
                mode: .maintaining(limit: 80),
                charge: 79,
                isPluggedIn: true,
                inhibitionOwnership: .none,
                operationPending: false
            ),
            .acquire(limit: 80)
        )
    }

    func testOwnedInhibitionReleasesWhenFeatureNoLongerEligible() {
        let ineligibleModes: [ChargeMode] = [
            .toppingUp(returnLimit: 80),
            .discharging(target: 60, returnLimit: 80),
            .heatBlocked(previous: .maintaining(limit: 80)),
            .controlDisabled(lastLimit: 80)
        ]
        for mode in ineligibleModes {
            XCTAssertEqual(
                SleepChargingPolicy.awakeAction(
                    strategy: .finishChargingThenSleep,
                    ownsBatteryControl: true,
                    mode: mode,
                    charge: 50,
                    isPluggedIn: true,
                    inhibitionOwnership: .batteryGuard,
                    operationPending: false
                ),
                .release
            )
        }
    }

    func testTargetRequiresVerifiedReleaseOnlyForOwnedInhibition() {
        XCTAssertEqual(
            SleepChargingPolicy.awakeAction(
                strategy: .finishChargingThenSleep,
                ownsBatteryControl: true,
                mode: .maintaining(limit: 80),
                charge: 80,
                isPluggedIn: true,
                inhibitionOwnership: .batteryGuard,
                operationPending: false
            ),
            .verifyLimitThenRelease(limit: 80)
        )
        XCTAssertEqual(
            SleepChargingPolicy.awakeAction(
                strategy: .finishChargingThenSleep,
                ownsBatteryControl: true,
                mode: .maintaining(limit: 80),
                charge: 80,
                isPluggedIn: true,
                inhibitionOwnership: .external,
                operationPending: false
            ),
            .none
        )
    }

    func testExternalOwnershipIsRecheckedBelowLimit() {
        XCTAssertEqual(
            SleepChargingPolicy.awakeAction(
                strategy: .finishChargingThenSleep,
                ownsBatteryControl: true,
                mode: .maintaining(limit: 80),
                charge: 60,
                isPluggedIn: true,
                inhibitionOwnership: .external,
                operationPending: false
            ),
            .acquire(limit: 80)
        )
    }

    func testOwnedInhibitionIsReverifiedBelowLimit() {
        XCTAssertEqual(
            SleepChargingPolicy.awakeAction(
                strategy: .finishChargingThenSleep,
                ownsBatteryControl: true,
                mode: .maintaining(limit: 80),
                charge: 60,
                isPluggedIn: true,
                inhibitionOwnership: .batteryGuard,
                operationPending: false
            ),
            .acquire(limit: 80)
        )
    }
}

final class SystemSleepInhibitorTests: XCTestCase {
    func testAcquireAndReleaseRoundTripsOwnedSleepDisabledLease() async throws {
        let fixture = try makeSleepInhibitorFixture(initialValue: "0")
        defer { fixture.cleanup() }
        let inhibitor = SystemSleepInhibitor(
            sudoPath: fixture.sudo.path,
            pmsetPath: fixture.pmset.path,
            shellPath: "/bin/sh",
            batteryPath: fixture.battery.path,
            journalURL: fixture.journal,
            trustPolicy: .testFixture,
            processID: getpid()
        )

        let ownership = try await inhibitor.acquire(until: 80, maximumDuration: 60)
        XCTAssertEqual(ownership, .batteryGuard)
        XCTAssertEqual(try fixture.readState(), "1")

        try await inhibitor.releaseOwnedInhibition()
        XCTAssertEqual(try fixture.readState(), "0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testExternalSleepDisabledIsObservedWithoutBeingCleared() async throws {
        let fixture = try makeSleepInhibitorFixture(initialValue: "1")
        defer { fixture.cleanup() }
        let inhibitor = SystemSleepInhibitor(
            sudoPath: fixture.sudo.path,
            pmsetPath: fixture.pmset.path,
            shellPath: "/bin/sh",
            batteryPath: fixture.battery.path,
            journalURL: fixture.journal,
            trustPolicy: .testFixture,
            processID: getpid()
        )

        let ownership = try await inhibitor.acquire(until: 80, maximumDuration: 60)
        XCTAssertEqual(ownership, .external)
        do {
            try await inhibitor.releaseOwnedInhibition()
            XCTFail("missing ownership lease must prevent release")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ownership lease is missing"))
        }

        XCTAssertEqual(try fixture.readState(), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testWatchdogStopsMaintainAndChargingWhenOwnerDies() async throws {
        let fixture = try makeSleepInhibitorFixture(initialValue: "0")
        defer { fixture.cleanup() }
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["30"]
        try owner.run()
        let inhibitor = SystemSleepInhibitor(
            sudoPath: fixture.sudo.path,
            pmsetPath: fixture.pmset.path,
            shellPath: "/bin/sh",
            batteryPath: fixture.battery.path,
            journalURL: fixture.journal,
            trustPolicy: .testFixture,
            processID: owner.processIdentifier
        )
        let ownership = try await inhibitor.acquire(until: 80, maximumDuration: 60)
        XCTAssertEqual(ownership, .batteryGuard)

        owner.terminate()
        while owner.isRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, try fixture.readState() != "0" {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(try fixture.readState(), "0")
        let batteryCommands = try String(contentsOf: fixture.batteryLog, encoding: .utf8)
        XCTAssertTrue(batteryCommands.contains("maintain stop\ncharging off"))
        try await inhibitor.releaseOwnedInhibition()
    }

    func testMissingOwnedSleepDisabledStateIsReacquired() async throws {
        let fixture = try makeSleepInhibitorFixture(initialValue: "0")
        defer { fixture.cleanup() }
        let inhibitor = SystemSleepInhibitor(
            sudoPath: fixture.sudo.path,
            pmsetPath: fixture.pmset.path,
            shellPath: "/bin/sh",
            batteryPath: fixture.battery.path,
            journalURL: fixture.journal,
            trustPolicy: .testFixture,
            processID: getpid()
        )
        _ = try await inhibitor.acquire(until: 80, maximumDuration: 60)
        try fixture.writeState("0")

        let ownership = try await inhibitor.acquire(until: 80, maximumDuration: 60)

        XCTAssertEqual(ownership, .batteryGuard)
        XCTAssertEqual(try fixture.readState(), "1")
        try await inhibitor.releaseOwnedInhibition()
    }

    func testExpiredLeaseStopsChargingAndCannotExtendItself() async throws {
        let fixture = try makeSleepInhibitorFixture(initialValue: "0")
        defer { fixture.cleanup() }
        let clock = TestClock(Date())
        let inhibitor = SystemSleepInhibitor(
            sudoPath: fixture.sudo.path,
            pmsetPath: fixture.pmset.path,
            shellPath: "/bin/sh",
            batteryPath: fixture.battery.path,
            journalURL: fixture.journal,
            trustPolicy: .testFixture,
            processID: getpid(),
            now: { clock.now() }
        )
        _ = try await inhibitor.acquire(until: 80, maximumDuration: 60)
        clock.advance(by: 61)

        do {
            _ = try await inhibitor.acquire(until: 80, maximumDuration: 60)
            XCTFail("an expired lease must not silently extend its deadline")
        } catch let error as SleepInhibitionError {
            XCTAssertEqual(error, .maximumDurationExceeded)
        }

        XCTAssertEqual(try fixture.readState(), "0")
        let batteryCommands = try String(contentsOf: fixture.batteryLog, encoding: .utf8)
        XCTAssertTrue(batteryCommands.contains("maintain stop\ncharging off"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testCorruptMarkerPathCannotDeleteAnArbitraryFileOrClearExternalSleepState() async throws {
        let fixture = try makeSleepInhibitorFixture(initialValue: "1")
        defer { fixture.cleanup() }
        let sentinel = fixture.directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let lease: [String: Any] = [
            "phase": "owned",
            "ownerPID": Int(getpid()),
            "releaseMarkerPath": sentinel.path,
            "deadline": Date().addingTimeInterval(60).timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: lease)
        try data.write(to: fixture.journal)
        let inhibitor = SystemSleepInhibitor(
            sudoPath: fixture.sudo.path,
            pmsetPath: fixture.pmset.path,
            shellPath: "/bin/sh",
            batteryPath: fixture.battery.path,
            journalURL: fixture.journal,
            trustPolicy: .testFixture,
            processID: getpid()
        )

        do {
            try await inhibitor.releaseOwnedInhibition()
            XCTFail("an invalid release marker must reject the lease")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertEqual(try fixture.readState(), "1")
        }
    }

    private func makeSleepInhibitorFixture(initialValue: String) throws -> SleepInhibitorFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-sleep-inhibitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = directory.appendingPathComponent("state")
        try Data(initialValue.utf8).write(to: state)
        let pmset = try makeExecutableFixture("""
        #!/bin/sh
        state=\(shellQuote(state.path))
        if [ "$1" = "-g" ]; then
          printf ' SleepDisabled %s\\n' "$(/bin/cat "$state")"
          exit 0
        fi
        [ "$1" = "-a" ] && [ "$2" = "disablesleep" ] || exit 64
        printf '%s' "$3" > "$state"
        """)
        let sudo = try makeExecutableFixture("""
        #!/bin/sh
        [ "$1" = "-n" ] && shift
        [ "$1" = "-l" ] && exit 0
        exec "$@"
        """)
        let batteryLog = directory.appendingPathComponent("battery.log")
        let battery = try makeExecutableFixture("""
        #!/bin/sh
        printf '%s\\n' "$*" >> \(shellQuote(batteryLog.path))
        exit 0
        """)
        return SleepInhibitorFixture(
            directory: directory,
            state: state,
            pmset: pmset,
            sudo: sudo,
            battery: battery,
            batteryLog: batteryLog,
            journal: directory.appendingPathComponent("lease.json")
        )
    }
}

final class SleepAcknowledgedOperationTests: XCTestCase {
    func testTimeoutCancelsCleanupAndAcknowledgesExactlyOnce() async {
        let acknowledgementCount = LockedCounter()
        let operation = SleepAcknowledgedOperation(deadline: 0.02) {
            acknowledgementCount.increment()
        }
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        operation.setTask(task)

        try? await Task.sleep(nanoseconds: 50_000_000)
        operation.finish()

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(acknowledgementCount.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private struct SleepInhibitorFixture {
    let directory: URL
    let state: URL
    let pmset: URL
    let sudo: URL
    let battery: URL
    let batteryLog: URL
    let journal: URL

    func readState() throws -> String {
        try String(contentsOf: state, encoding: .utf8)
    }

    func writeState(_ value: String) throws {
        try Data(value.utf8).write(to: state, options: .atomic)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: pmset)
        try? FileManager.default.removeItem(at: sudo)
        try? FileManager.default.removeItem(at: battery)
    }
}

@MainActor
extension ChargeControllerSafetyTests {
    func testDefaultStrategyPausesAndWakeRestoresVerifiedMaintain() async {
        let inhibitor = FakeSystemSleepInhibitor()
        let (controller, backend, _, _) = makeSUT(
            charge: 67,
            initialMode: .toppingUp(returnLimit: 80),
            sleepInhibitor: inhibitor
        )
        backend.setOwnedLongRunningOperation(true)

        await controller.prepareForSleep()

        XCTAssertEqual(controller.mode, .sleepProtected(previous: .toppingUp(returnLimit: 80), charge: 67))
        XCTAssertEqual(controller.sleepProtectionState, .pausedForSleep(charge: 67))
        XCTAssertTrue(backend.operations.contains("cancel-long"))
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        let sleepOperations = await inhibitor.operations
        XCTAssertEqual(sleepOperations, [])

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

        await controller.prepareForSleep()

        guard case .failed(_, _, .manualIntervention) = controller.mode else {
            return XCTFail("unverified charging state must fail closed")
        }
        guard case .unavailable = controller.sleepProtectionState else {
            return XCTFail("sleep protection failure must be visible")
        }
    }

    func testHotWakeNeverResumesInterruptedTopUp() async {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 70,
            initialMode: .sleepProtected(previous: .toppingUp(returnLimit: 80), charge: 70)
        )
        backend.temperature = 45

        await controller.reconcileAfterWake()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: .maintaining(limit: 80)))
        XCTAssertFalse(backend.operations.contains("top-up:100"))
    }

    func testDisabledStrategyDoesNotMutateBatteryState() async {
        let (controller, backend, _, _) = makeSUT(
            initialMode: .maintaining(limit: 80),
            sleepChargingStrategy: .disabled
        )

        await controller.prepareForSleep()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(backend.operations.contains("disable-charging"))
    }

    func testFinishThenSleepAcquiresAndReleasesOnlyOwnedInhibition() async {
        let inhibitor = FakeSystemSleepInhibitor()
        let (controller, _, _, _) = makeSUT(
            charge: 60,
            initialMode: .maintaining(limit: 80),
            sleepChargingStrategy: .finishChargingThenSleep,
            sleepInhibitor: inhibitor
        )

        controller.processBatteryInfo(makeBatteryInfo(charge: 60))
        let acquired = await eventually {
            controller.sleepProtectionState == .holdingAwake(limit: 80, ownership: .batteryGuard)
        }
        XCTAssertTrue(acquired)

        controller.processBatteryInfo(makeBatteryInfo(charge: 80))
        let released = await eventually { controller.sleepProtectionState == .ready }
        XCTAssertTrue(released)
        let operations = await inhibitor.operations
        XCTAssertEqual(operations.filter { $0 == "release" }.count, 1)
    }

    func testExternalSleepDisabledIsNeverReleased() async {
        let inhibitor = FakeSystemSleepInhibitor()
        await inhibitor.setAcquireOwnership(.external)
        let (controller, _, _, _) = makeSUT(
            charge: 60,
            initialMode: .maintaining(limit: 80),
            sleepChargingStrategy: .finishChargingThenSleep,
            sleepInhibitor: inhibitor
        )

        controller.processBatteryInfo(makeBatteryInfo(charge: 60))
        let detectedExternalOwnership = await eventually {
            controller.sleepProtectionState == .holdingAwake(limit: 80, ownership: .external)
        }
        XCTAssertTrue(detectedExternalOwnership)
        controller.processBatteryInfo(makeBatteryInfo(charge: 80))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let operations = await inhibitor.operations
        XCTAssertFalse(operations.contains("release"))
    }
}
