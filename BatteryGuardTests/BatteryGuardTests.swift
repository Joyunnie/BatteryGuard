import XCTest
import ServiceManagement
import Combine
import Darwin
import AppKit
@testable import BatteryGuard


final class ChargeStateTests: XCTestCase {
    func testAllStatesHaveStableLabels() {
        XCTAssertEqual(ChargeState.unknown.rawValue, "상태 확인 필요")
        XCTAssertEqual(ChargeState.charging.rawValue, "충전 중")
        XCTAssertEqual(ChargeState.chargingPaused.rawValue, "충전 일시정지")
        XCTAssertEqual(ChargeState.discharging.rawValue, "방전 중")
        XCTAssertEqual(ChargeState.notConnected.rawValue, "전원 미연결")
        XCTAssertEqual(ChargeState.topUp.rawValue, "Top Up 중")
    }
}

@MainActor
final class UserSettingsTests: XCTestCase {
    func testBatteryControlOwnershipDefaultsEnabledAndPersistsExplicitRelease() throws {
        let defaults = makeTestDefaults()
        let journalURL = makeOwnershipJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let settings = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )

        XCTAssertTrue(settings.batteryControlEnabled)
        try settings.completeBatteryControlRelease(lastLimit: 75)

        let reloaded = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )
        XCTAssertFalse(reloaded.batteryControlEnabled)
        XCTAssertEqual(reloaded.batteryControlOwnership, .system(lastLimit: 75))
    }

    func testPendingControlReleaseSurvivesRestartWithoutClaimingReleasedState() throws {
        let defaults = makeTestDefaults()
        let journalURL = makeOwnershipJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let settings = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )

        try settings.beginBatteryControlRelease(lastLimit: 70)

        let reloaded = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )
        XCTAssertFalse(reloaded.batteryControlEnabled)
        XCTAssertTrue(reloaded.batteryControlReleasePending)
        XCTAssertTrue(reloaded.expectsReleasedBatteryControl)
        XCTAssertEqual(reloaded.batteryControlOwnership, .releasing(lastLimit: 70))
    }

    func testDefaultsAndPersistenceUseIsolatedDefaults() {
        let defaults = makeTestDefaults()
        let settings = UserSettings(defaults: defaults, launchAtLoginService: FakeLaunchAtLoginService())

        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertEqual(settings.heatProtectionThreshold, 40)

        settings.chargeLimit = 65
        settings.heatProtectionThreshold = 35
        XCTAssertEqual(defaults.integer(forKey: "chargeLimit"), 65)
        XCTAssertEqual(defaults.double(forKey: "heatThreshold"), 35)
    }

    func testInvalidValuesAreClampedBeforePublicationAndPersistence() {
        let defaults = makeTestDefaults()
        defaults.set(0, forKey: "chargeLimit")
        defaults.set(Double.nan, forKey: "heatThreshold")
        let settings = UserSettings(defaults: defaults, launchAtLoginService: FakeLaunchAtLoginService())

        XCTAssertEqual(settings.chargeLimit, 20)
        XCTAssertEqual(settings.heatProtectionThreshold, 40)

        var publishedChargeLimits: [Int] = []
        let cancellable = settings.objectWillChange.sink {
            publishedChargeLimits.append(settings.chargeLimit)
        }
        settings.chargeLimit = 500

        XCTAssertEqual(settings.chargeLimit, 100)
        XCTAssertFalse(publishedChargeLimits.contains(500))
        XCTAssertEqual(defaults.integer(forKey: "chargeLimit"), 100)
        _ = cancellable
    }

    func testLaunchAtLoginUsesInjectedServiceWithoutChangingSystemState() {
        let service = FakeLaunchAtLoginService()
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.launchAtLogin = true
        XCTAssertEqual(service.status, .enabled)
        XCTAssertTrue(settings.launchAtLogin)

        settings.launchAtLogin = false
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testLaunchAtLoginRollsBackWhenInjectedServiceFails() {
        let service = FakeLaunchAtLoginService()
        service.registerError = BatteryError.commandFailed("register", 1, "denied")
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.launchAtLogin = true
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNotNil(settings.launchAtLoginError)
    }

    func testLaunchAtLoginPreservesRequiresApprovalState() {
        let service = FakeLaunchAtLoginService()
        service.statusAfterRegister = .requiresApproval
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginState, .requiresApproval)
    }

    func testLaunchAtLoginReportsAStatusMismatchAfterRegistrationReturns() {
        let service = FakeLaunchAtLoginService()
        service.statusAfterRegister = .notRegistered
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.setLaunchAtLogin(true)

        XCTAssertEqual(settings.launchAtLoginState, .disabled)
        XCTAssertNotNil(settings.launchAtLoginError)
    }

    func testRefreshingLaunchAtLoginStatusClearsAStaleActionError() {
        let service = FakeLaunchAtLoginService()
        service.registerError = BatteryError.commandFailed("register", 1, "denied")
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)
        settings.setLaunchAtLogin(true)
        XCTAssertNotNil(settings.launchAtLoginError)

        service.registerError = nil
        service.status = .enabled
        settings.refreshLaunchAtLoginStatus()

        XCTAssertEqual(settings.launchAtLoginState, .enabled)
        XCTAssertNil(settings.launchAtLoginError)
    }
}

@MainActor
final class AppActivationControllerTests: XCTestCase {
    func testShowingAWindowAppliesRegularPolicyBeforeActivation() {
        var calls: [String] = []
        let controller = AppActivationController(
            setPolicy: { policy in
                calls.append("policy:\(policy.rawValue)")
                return true
            },
            activate: { calls.append("activate") },
            hasVisibleAppWindow: { false },
            diagnostics: .disabled
        )

        XCTAssertTrue(controller.showAppWindow())
        XCTAssertEqual(calls, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate"])
    }

    func testRejectedRegularPolicyDoesNotPretendToActivate() {
        var didActivate = false
        let controller = AppActivationController(
            setPolicy: { _ in false },
            activate: { didActivate = true },
            hasVisibleAppWindow: { false },
            diagnostics: .disabled
        )

        XCTAssertFalse(controller.showAppWindow())
        XCTAssertFalse(didActivate)
    }

    func testAccessoryPolicyIsRestoredOnlyAfterTheLastWindowCloses() {
        var hasVisibleWindow = true
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = AppActivationController(
            setPolicy: { policies.append($0); return true },
            activate: {},
            hasVisibleAppWindow: { hasVisibleWindow },
            diagnostics: .disabled
        )

        XCTAssertTrue(controller.restoreAccessoryPolicyIfNeeded())
        XCTAssertTrue(policies.isEmpty)
        hasVisibleWindow = false
        XCTAssertTrue(controller.restoreAccessoryPolicyIfNeeded())
        XCTAssertEqual(policies, [.accessory])
    }
}

final class StatusParsingTests: XCTestCase {
    func testParsesCompleteStatusCSV() {
        XCTAssertEqual(
            SMCKit.parseControlStatus(csv: "80,00:10,disabled,not discharging,80"),
            BatteryControlStatus(charging: .disabled, isDischarging: false, maintainLevel: 80)
        )
        XCTAssertEqual(
            SMCKit.parseControlStatus(csv: "79,00:10,enabled,discharging,65"),
            BatteryControlStatus(charging: .enabled, isDischarging: true, maintainLevel: 65)
        )
    }

    func testRejectsMalformedStatusInsteadOfGuessing() {
        XCTAssertNil(SMCKit.parseControlStatus(csv: ""))
        XCTAssertNil(SMCKit.parseControlStatus(csv: "80,00:10,disabled"))
        XCTAssertEqual(SMCKit.parseChargingStatus(csv: "bad"), .unknown)
    }

    func testMaintainWorkerClassificationRejectsDuplicatesAndStalePIDFiles() {
        let path = "/usr/local/co.palokaj.battery/battery"
        let processTable = """
         101 100 /bin/bash \(path) maintain_synchronous 80
         202 200 /bin/bash \(path) maintain_synchronous 80
         303 300 /bin/bash /tmp/unrelated maintain_synchronous 80
        """

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 202,
                processTable: processTable,
                batteryPath: path
            ),
            .duplicate(pids: [101, 202])
        )
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 404,
                processTable: "101 100 /bin/bash \(path) maintain_synchronous 80",
                batteryPath: path
            ),
            .stale(pid: 404)
        )
    }

    func testMaintainWorkerClassificationRequiresExactCommandTokens() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        let unrelated = "123 123 /tmp/helper --note=\(batteryPath) --mode=maintain_synchronous"

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 123,
                processTable: unrelated,
                batteryPath: batteryPath
            ),
            .stale(pid: 123)
        )

        let standaloneTokens = "123 123 /bin/echo \(batteryPath) maintain_synchronous 80"
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 123,
                processTable: standaloneTokens,
                batteryPath: batteryPath
            ),
            .stale(pid: 123)
        )
    }

    func testMaintainWorkerClassificationBindsTheWorkerTarget() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 101,
                processTable: "101 100 /bin/bash \(batteryPath) maintain_synchronous 60",
                batteryPath: batteryPath
            ),
            .running(pid: 101, target: 60)
        )
    }
}

final class ProcessLifecycleTests: XCTestCase {
    private let termIgnoringShell = ["-c", "trap '' TERM; while true; do :; done"]

    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    func testTimeoutEscalatesAndReturnsStructuredResultWithinBoundedTime() async throws {
        let backend = SMCKit()
        let startedAt = Date()

        let result = try await backend.runFixtureForTesting(
            executable: "/bin/sh",
            arguments: termIgnoringShell,
            timeout: 0.05
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testExternalCancellationReachesRunningProcess() async throws {
        let backend = SMCKit()
        let arguments = termIgnoringShell
        let operation = Task {
            try await backend.runFixtureForTesting(
                executable: "/bin/sh",
                arguments: arguments,
                timeout: 5
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await backend.requestCancellation()
        let result = try await operation.value

        XCTAssertEqual(result.termination, .cancelled)
    }

    func testTaskCancellationStopsChildAndThrowsCancellation() async throws {
        let runner = BatteryCommandRunner()
        let arguments = termIgnoringShell
        let operation = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: arguments,
                    label: "task cancellation fixture",
                    timeout: 5
                )
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected: cancellation propagated through the runner to the child.
        }
    }

    func testSpawnFailurePreservesCommandLabel() async {
        let runner = BatteryCommandRunner()
        do {
            _ = try await runner.run(
                .init(
                    executable: "/definitely/missing/batteryguard-fixture",
                    arguments: [],
                    label: "missing fixture",
                    timeout: 1
                )
            )
            XCTFail("Expected spawn failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing fixture"))
        }
    }

    func testCapturesStdoutStderrAndExitCode() async throws {
        let backend = SMCKit()
        let result = try await backend.runFixtureForTesting(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"],
            timeout: 1
        )

        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    func testRunnerSerializesQueuedCommands() async throws {
        let runner = BatteryCommandRunner()
        let eventFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-serialization-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: eventFile) }
        let quotedEventFile = shellQuote(eventFile.path)
        let first = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo first-start >> \(quotedEventFile); sleep 0.2; echo first-end >> \(quotedEventFile); printf first"
                    ],
                    label: "first",
                    timeout: 1
                )
            )
        }
        let firstStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("first-start")) == true
        }
        XCTAssertTrue(firstStarted)

        let second = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "echo second >> \(quotedEventFile); printf second"],
                label: "second",
                timeout: 1
            )
        )

        let firstResult = try await first.value
        XCTAssertEqual(firstResult.stdout, "first")
        XCTAssertEqual(second.stdout, "second")
        let events = try String(contentsOf: eventFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }

    func testLongRunningLaunchWaitsForActiveOneShotCommand() async throws {
        let runner = BatteryCommandRunner()
        let eventFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-long-serialization-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: eventFile) }
        let quotedEventFile = shellQuote(eventFile.path)

        let first = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo one-shot-start >> \(quotedEventFile); sleep 0.2; echo one-shot-end >> \(quotedEventFile)"
                    ],
                    label: "one-shot before long launch",
                    timeout: 1
                )
            )
        }
        let oneShotStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("one-shot-start")) == true
        }
        XCTAssertTrue(oneShotStarted)

        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo long-start >> \(quotedEventFile); trap '' TERM; while true; do :; done"
                ],
                label: "serialized long launch"
            )
        )
        _ = try await first.value
        let longStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("long-start")) == true
        }
        XCTAssertTrue(longStarted)
        _ = try await runner.cancelLongRunning()

        let events = try String(contentsOf: eventFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(events, ["one-shot-start", "one-shot-end", "long-start"])
    }

    func testCapturedOutputIsBounded() async throws {
        let runner = BatteryCommandRunner()
        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 100000"],
                label: "bounded output fixture",
                timeout: 1
            )
        )

        XCTAssertEqual(result.stdout.utf8.count, 64 * 1024)
        XCTAssertTrue(result.stdoutWasTruncated)
        XCTAssertFalse(result.stderrWasTruncated)
        XCTAssertEqual(result.termination, .exited)
    }

    func testDiscardedStdoutStillCapturesBoundedStderr() async throws {
        let runner = BatteryCommandRunner()
        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/yes e | /usr/bin/head -c 100000 >&2"],
                label: "bounded stderr fixture",
                timeout: 1,
                outputPolicy: .discardStdoutCaptureStderr
            )
        )

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.utf8.count, 64 * 1024)
        XCTAssertTrue(result.stderrWasTruncated)
    }

    func testStderrCaptureDoesNotWaitForADetachedDescendantToCloseThePipe() async throws {
        let runner = BatteryCommandRunner()
        let parentPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-stderr-parent-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: parentPIDFile) }
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \(shellQuote(parentPIDFile.path)); printf parent-error >&2; sleep 30 & exit 7"
                ],
                label: "inherited stderr fixture",
                timeout: 1,
                outputPolicy: .discardStdoutCaptureStderr
            )
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let parentPID = try XCTUnwrap(Int32(
            String(contentsOf: parentPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        _ = Darwin.kill(-parentPID, SIGTERM)

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stderr, "parent-error")
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testPersistentDescendantPolicyReturnsWithoutKillingTheWorker() async throws {
        let runner = BatteryCommandRunner()
        let parentPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-persistent-parent-\(UUID().uuidString).pid")
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-persistent-child-\(UUID().uuidString).pid")
        defer {
            try? FileManager.default.removeItem(at: parentPIDFile)
            try? FileManager.default.removeItem(at: childPIDFile)
        }

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \(shellQuote(parentPIDFile.path)); sleep 30 & echo $! > \(shellQuote(childPIDFile.path)); printf launched"
                ],
                label: "persistent descendant fixture",
                timeout: 1,
                descendantPolicy: .allowPersistentProcessGroup
            )
        )
        let parentPID = try XCTUnwrap(Int32(
            String(contentsOf: parentPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { _ = Darwin.kill(-parentPID, SIGKILL) }

        XCTAssertEqual(result.stdout, "launched")
        XCTAssertEqual(Darwin.kill(childPID, 0), 0)
    }

    func testSecondLongRunningLaunchIsRejectedWithoutStoppingTheFirst() async throws {
        let runner = BatteryCommandRunner()
        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: termIgnoringShell,
                label: "first long fixture"
            )
        )

        do {
            _ = try await runner.launchLongRunning(
                .init(
                    executable: "/bin/sh",
                    arguments: ["-c", "exit 0"],
                    label: "second long fixture"
                )
            )
            XCTFail("Expected the second long-running launch to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("first long fixture"))
        }

        let firstIsStillActive = await runner.isLongRunningActive()
        XCTAssertTrue(firstIsStillActive)
        _ = try await runner.cancelLongRunning()
    }

    func testLongRunningCommandUsesItsMonotonicTimeout() async throws {
        let runner = BatteryCommandRunner()
        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: termIgnoringShell,
                label: "timed long fixture",
                timeout: 0.05
            )
        )
        let deadline = Date().addingTimeInterval(3)
        var result: BatteryCommandResult?
        while result == nil, Date() < deadline {
            result = await runner.longRunningResult()
            if result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let isActive = await runner.isLongRunningActive()
        XCTAssertFalse(isActive)
        XCTAssertEqual(result?.termination, .timedOut)
    }

    func testNonFiniteTimeoutsDoNotTrapTheRunner() async throws {
        let runner = BatteryCommandRunner()
        let infiniteResult = try await runner.run(
            .init(
                executable: "/usr/bin/true",
                arguments: [],
                label: "infinite timeout fixture",
                timeout: .infinity
            )
        )
        XCTAssertEqual(infiniteResult.termination, .exited)

        let nanResult = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while true; do :; done"],
                label: "nan timeout fixture",
                timeout: .nan
            )
        )
        XCTAssertEqual(nanResult.termination, .timedOut)
    }

    func testCancelAllRejectsCommandsQueuedDuringCancellation() async throws {
        let runner = BatteryCommandRunner()
        let arguments = termIgnoringShell
        let active = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: arguments,
                    label: "active cancellation fixture",
                    timeout: 5
                )
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancellation = Task { try await runner.cancelAll() }
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            _ = try await runner.run(
                .init(executable: "/bin/true", arguments: [], label: "late command")
            )
            XCTFail("Expected enqueue to be rejected during cancellation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cancellation"))
        }

        try await cancellation.value
        _ = try await active.value
    }

    func testTimeoutLeavesNoFixtureProcessBehind() async throws {
        let runner = BatteryCommandRunner()
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-runner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > '\(pidFile.path)'; trap '' TERM; while true; do :; done"
                ],
                label: "timeout cleanup fixture",
                timeout: 0.05
            )
        )

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutKillsDescendantsInTheSpawnedProcessGroup() async throws {
        let runner = BatteryCommandRunner()
        let parentPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-parent-\(UUID().uuidString).pid")
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-child-\(UUID().uuidString).pid")
        defer {
            try? FileManager.default.removeItem(at: parentPIDFile)
            try? FileManager.default.removeItem(at: childPIDFile)
        }

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \(shellQuote(parentPIDFile.path)); sleep 30 & echo $! > \(shellQuote(childPIDFile.path)); trap '' TERM; while true; do :; done"
                ],
                label: "process group cleanup fixture",
                timeout: 0.05
            )
        )

        let parentPID = try XCTUnwrap(Int32(
            String(contentsOf: parentPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        XCTAssertEqual(result.termination, .timedOut)
        let parentExited = await eventually { Darwin.kill(parentPID, 0) == -1 && errno == ESRCH }
        let childExited = await eventually { Darwin.kill(childPID, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(parentExited)
        XCTAssertTrue(childExited)
    }

    func testLongRunningEarlyExitPreservesFailureOutput() async throws {
        let runner = BatteryCommandRunner()
        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "printf long-failure >&2; exit 9"],
                label: "long fixture",
                timeout: 1
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let isActive = await runner.isLongRunningActive()
        let capturedResult = await runner.longRunningResult()
        XCTAssertFalse(isActive)
        let result = try XCTUnwrap(capturedResult)
        XCTAssertEqual(result.exitCode, 9)
        XCTAssertEqual(result.stderr, "long-failure")
        XCTAssertEqual(result.termination, .exited)
    }
}

final class SMCKitOperationSafetyTests: XCTestCase {
    private func eventually(
        timeout: TimeInterval = 2.5,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    func testFailedLongRunningVerificationCleansUpTheStartedProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-verification-\(UUID().uuidString).pid")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            case "$1" in
              charge)
                echo $$ > \(shellQuote(pidFile.path))
                trap '' TERM
                while true; do :; done
                ;;
              status_csv)
                echo verification-status-failed >&2
                exit 7
                ;;
            esac
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.startTopUp(to: 100)
            XCTFail("Expected status verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("verification-status-failed"))
        }

        let pid = try XCTUnwrap(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let processExited = await eventually { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
        let isStillActive = await backend.isLongRunningOperationActive()
        XCTAssertTrue(processExited)
        XCTAssertFalse(isStillActive)
    }

    func testDischargeVerificationAcceptsCLIForceDischargeTuple() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-discharge-\(UUID().uuidString).pid")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            case "$1" in
              discharge)
                echo $$ > \(shellQuote(pidFile.path))
                while true; do sleep 1; done
                ;;
              status_csv)
                if [[ -s \(shellQuote(pidFile.path)) ]]; then
                  echo "81,attached;,enabled,discharging,80"
                else
                  echo "81,attached;,disabled,not discharging,80"
                fi
                ;;
            esac
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.startDischarge(to: 80)
        let isActive = await backend.isLongRunningOperationActive()
        XCTAssertTrue(isActive)

        try await backend.cancelLongRunningOperation()
        let pid = try XCTUnwrap(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let processExited = await eventually { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(processExited)
    }

    func testControlCommandAndVerificationRemainAtomic() async throws {
        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-maintain-state-\(UUID().uuidString)")
        let eventFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-maintain-events-\(UUID().uuidString)")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            case "$1" in
              maintain)
                echo "$2" > \(shellQuote(stateFile.path))
                echo "maintain-$2" >> \(shellQuote(eventFile.path))
                sleep 0.15
                ;;
              status_csv)
                value=$(cat \(shellQuote(stateFile.path)))
                echo "status-$value" >> \(shellQuote(eventFile.path))
                echo "80,00:10,disabled,not discharging,$value"
                ;;
            esac
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: stateFile)
            try? FileManager.default.removeItem(at: eventFile)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in
                guard
                    let rawTarget = try? String(contentsOf: stateFile, encoding: .utf8),
                    let target = Int(rawTarget.trimmingCharacters(in: .whitespacesAndNewlines))
                else {
                    return .stopped
                }
                return .running(pid: 4_242, target: target)
            },
            executableTrustPolicy: .testFixture
        )

        let first = Task { try await backend.applyMaintain(level: 60) }
        let firstMaintainStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("maintain-60")) == true
        }
        XCTAssertTrue(firstMaintainStarted)
        let second = Task { try await backend.applyMaintain(level: 80) }
        try await first.value
        try await second.value

        let events = try String(contentsOf: eventFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(events, ["maintain-60", "status-60", "maintain-80", "status-80"])
    }

    func testVerifiedOperationAndItsCommandsShareOneCorrelationID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-smc-correlation-\(UUID().uuidString)", isDirectory: true)
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: directory)
        }
        let runner = BatteryCommandRunner(diagnostics: log)
        let backend = SMCKit(
            runner: runner,
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242, target: 80) },
            executableTrustPolicy: .testFixture,
            diagnostics: log
        )

        try await backend.applyMaintain(level: 80)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if events.contains(where: { $0.category == .control }) &&
                events.filter({ $0.category == .command }).count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(events.contains { $0.operation == "maintain 80" && $0.category == .control })
        XCTAssertTrue(events.contains { $0.operation.contains("status_csv") && $0.category == .command })
        XCTAssertEqual(Set(events.compactMap(\.operationID)).count, 1)
        XCTAssertTrue(events.allSatisfy { $0.operationID != nil })
    }

    func testMaintainVerificationRejectsADeadWorkerEvenWhenTrackerMatches() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.applyMaintain(level: 80)
            XCTFail("Expected dead worker verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("worker=stopped"))
        }
    }

    func testMaintainVerificationRejectsConcurrentDischarge() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,discharging,80"
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242, target: 80) },
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.applyMaintain(level: 80)
            XCTFail("Expected concurrent discharge verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("discharging=true"))
        }
    }

    func testDisableChargingRequiresNoDischargeAndNoMaintainWorker() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,discharging,80"
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.disableCharging()
            XCTFail("Expected incomplete charging-off verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fully disabled"))
        }
    }

    func testReleaseControlRequiresEnabledChargingNoDischargeAndNoWorker() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-command-log-\(UUID().uuidString)")
        let processLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-process-log-\(UUID().uuidString)")
        let successFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf '%s\\n' "$*" >> \(shellQuote(commandLog.path))
            if [[ "$1" == "charge" ]]; then
              echo "$$" > \(shellQuote(processLog.path))
              trap '' TERM
              while true; do sleep 1; done
            fi
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,enabled,not discharging,80"
            fi
            """
        )
        let failureFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: successFixture)
            try? FileManager.default.removeItem(at: failureFixture)
            try? FileManager.default.removeItem(at: commandLog)
            if let pidText = try? String(contentsOf: processLog).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidText) {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: processLog)
        }

        let successBackend = SMCKit(
            batteryPath: successFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )
        try await successBackend.startTopUp(to: 100)
        let processPID = try XCTUnwrap(
            Int32(String(contentsOf: processLog).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(Darwin.kill(processPID, 0), 0)

        try await successBackend.releaseBatteryGuardControl()

        let commands = try String(contentsOf: commandLog)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(commands.filter { $0 == "maintain stop" }.count, 1)
        let ownsLongRunningOperation = await successBackend.isLongRunningOperationActive()
        XCTAssertFalse(ownsLongRunningOperation)
        let processExited = await eventually {
            Darwin.kill(processPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertTrue(processExited)

        let failureBackend = SMCKit(
            batteryPath: failureFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )
        do {
            try await failureBackend.releaseBatteryGuardControl()
            XCTFail("Expected released-control verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("released control"))
        }
    }

    func testBatteryCLIUsesOnlyPinnedAndSystemSearchPaths() async throws {
        let environmentLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-path-log-\(UUID().uuidString)")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf '%s' "$PATH" > \(shellQuote(environmentLog.path))
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: environmentLog)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242, target: 80) },
            executableTrustPolicy: .testFixture
        )

        try await backend.applyMaintain(level: 80)

        let path = try String(contentsOf: environmentLog, encoding: .utf8)
        XCTAssertEqual(
            path,
            "\(fixture.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        )
        XCTAssertFalse(path.split(separator: ":").contains("/usr/local/bin"))
    }

    func testProductionPreflightRejectsAnUnpinnedExecutableBeforeUse() async throws {
        let fixture = try makeExecutableFixture("#!/bin/bash\necho v1.3.4\n")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(batteryPath: fixture.path)

        do {
            try await backend.open()
            XCTFail("Expected production preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Battery CLI preflight failed"))
        }
    }

    func testPreflightRejectsAnUntrustedSMCBinaryBeforeExecutingBatteryCLI() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-preflight-marker-\(UUID().uuidString)")
        let batteryFixture = try makeExecutableFixture(
            "#!/bin/bash\necho invoked > \(shellQuote(marker.path))\n"
        )
        let smcTarget = try makeExecutableFixture("#!/bin/bash\nexit 0\n")
        let smcLink = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-smc-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: smcLink, withDestinationURL: smcTarget)
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcTarget)
            try? FileManager.default.removeItem(at: smcLink)
            try? FileManager.default.removeItem(at: marker)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcLink.path,
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.open()
            XCTFail("Expected SMC preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preflight failed"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testMaintainVerificationRejectsUnknownChargingAndMismatchedWorkerTarget() async throws {
        let cases: [(String, MaintainWorkerStatus)] = [
            ("unknown", .running(pid: 4_242, target: 80)),
            ("disabled", .running(pid: 4_242, target: 60))
        ]
        for (chargingText, worker) in cases {
            let fixture = try makeExecutableFixture(
                """
                #!/bin/bash
                if [[ "$1" == "status_csv" ]]; then
                  echo "80,00:10,\(chargingText),not discharging,80"
                fi
                """
            )
            defer { try? FileManager.default.removeItem(at: fixture) }
            let backend = SMCKit(
                batteryPath: fixture.path,
                maintainWorkerProbe: { _, _ in worker },
                executableTrustPolicy: .testFixture
            )
            do {
                try await backend.applyMaintain(level: 80)
                XCTFail("Expected incomplete Maintain tuple to fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("status_csv reported"))
            }
        }
    }

    func testMaintainFailurePreservesStderrWhenStdoutIsDiscarded() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "maintain" ]]; then
              echo maintain-error-detail >&2
              exit 23
            fi
            echo "80,00:10,disabled,not discharging,80"
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.applyMaintain(level: 80)
            XCTFail("Expected maintain failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("maintain-error-detail"))
            XCTAssertTrue(error.localizedDescription.contains("23"))
        }
    }

    func testLEDSnapshotAndRestoreCannotRace() async throws {
        let writeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-led-writes-\(UUID().uuidString)")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "version" ]]; then
              echo "v1.3.4"
            else
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$3" == "-r" ]]; then
              sleep 0.15
              echo "[ACLC] 0 (bytes 05)"
            elif [[ "$3" == "-w" ]]; then
              echo "$4" >> \(shellQuote(writeFile.path))
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: writeFile)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            usesSudoForSMCWrites: false,
            executableTrustPolicy: .testFixture
        )
        try await backend.open()

        let setTask = Task { try await backend.setMagSafeLED(.orange) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let restoreTask = Task { try await backend.restoreMagSafeLED() }
        try await setTask.value
        try await restoreTask.value

        let writes = try String(contentsOf: writeFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(writes, ["04", "05"])
    }
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
}

final class DiagnosticLogTests: XCTestCase {
    func testDiagnosticLogPersistsOnlyItsNewestHundredEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: fileURL, capacity: 100)

        for index in 0..<105 {
            await log.record(
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    category: .control,
                    operation: "operation-\(index)"
                )
            )
        }

        let events = await log.recentEvents()
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.operation, "operation-5")
        XCTAssertEqual(events.last?.operation, "operation-104")

        let reloaded = DiagnosticLog(fileURL: fileURL, capacity: 100)
        let reloadedEvents = await reloaded.recentEvents()
        XCTAssertEqual(reloadedEvents, events)
    }

    func testCommandRunnerRecordsStructuredFailureDetails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-command-log-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: fileURL, capacity: 10)
        let runner = BatteryCommandRunner(diagnostics: log)

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "echo diagnostic-failure >&2; exit 7"],
                label: "diagnostic fixture"
            )
        )
        XCTAssertEqual(result.exitCode, 7)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if !events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.last?.operation, "diagnostic fixture")
        XCTAssertEqual(events.last?.exitCode, 7)
        XCTAssertEqual(events.last?.message, "diagnostic-failure")
    }

    func testLongRunningLaunchAndExitUseUniqueEventIDsWithOneCorrelationID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-correlation-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = BatteryCommandRunner(diagnostics: log)
        let operationID = UUID()

        _ = try await DiagnosticContext.$operationID.withValue(operationID) {
            try await runner.launchLongRunning(
                .init(
                    executable: "/bin/sh",
                    arguments: ["-c", "trap '' TERM; while true; do :; done"],
                    label: "correlated fixture",
                    timeout: 2
                )
            )
        }
        _ = try await runner.cancelLongRunning()

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents().filter { $0.operation == "correlated fixture" }
            if events.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(Set(events.compactMap(\.commandID)).count, 1)
        XCTAssertEqual(Set(events.compactMap(\.operationID)), Set([operationID]))
        XCTAssertEqual(events.map(\.outcome), [.launched, .cancelled])
    }

    func testPrepareForViewingThrowsWhenTheLogCannotBePersisted() async throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-diagnostic-block-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let log = DiagnosticLog(
            fileURL: blockingFile.appendingPathComponent("Diagnostics.json"),
            capacity: 10
        )
        await log.record(DiagnosticEvent(category: .lifecycle, operation: "persist failure"))

        do {
            _ = try await log.prepareForViewing()
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLegacyDiagnosticSchemaIsMigratedWhenRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-legacy-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventID = UUID()
        let legacyJSON = """
        [{
          "id": "\(eventID.uuidString)",
          "timestamp": "2026-08-06T00:00:00Z",
          "category": "command",
          "operationID": "\(eventID.uuidString)",
          "operation": "legacy command",
          "exitCode": 7,
          "termination": "failedBeforeResult",
          "stderrSummary": "legacy failure"
        }]
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let events = await DiagnosticLog(fileURL: fileURL, capacity: 10).recentEvents()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, eventID)
        XCTAssertEqual(events.first?.commandID, eventID)
        XCTAssertEqual(events.first?.outcome, .failed)
        XCTAssertEqual(events.first?.message, "legacy failure")
    }
}

@MainActor
final class BatteryHistoryTests: XCTestCase {
    func testHistoryUsesInMemoryStoreAndDeduplicates() async {
        let history = BatteryHistory(inMemory: true)
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)
        history.record(chargePercent: 80, chargeLimit: 80)
        history.record(chargePercent: 80, chargeLimit: 80)

        let records = history.fetchLast24Hours()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.chargePercent, 80)
        XCTAssertEqual(records.first?.chargeLimit, 80)
    }

    func testHistoryAddsHeartbeatForAnUnchangedInterval() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let history = BatteryHistory(
            inMemory: true,
            heartbeatInterval: 900,
            now: { clock.now() }
        )
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)

        history.record(chargePercent: 80, chargeLimit: 80)
        clock.advance(by: 899)
        history.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertEqual(history.fetchLast24Hours().count, 1)

        clock.advance(by: 2)
        history.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertEqual(history.fetchLast24Hours().count, 2)
    }

    func testDownsamplingNeverExceedsTheConfiguredLimitAndKeepsEndpoints() {
        let records = (0..<1_003).map {
            BatteryHistory.ChartRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                chargePercent: $0 % 101,
                chargeLimit: 80
            )
        }

        let sampled = BatteryHistory.downsample(records, maxPoints: 200)

        XCTAssertEqual(sampled.count, 200)
        XCTAssertEqual(sampled.first, records.first)
        XCTAssertEqual(sampled.last, records.last)
        XCTAssertTrue(BatteryHistory.downsample(records, maxPoints: 0).isEmpty)
    }

    func testPersistentStoreLoadFailureIsExposed() async throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-history-block-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }

        let history = BatteryHistory(storeURL: blockingFile.appendingPathComponent("history.sqlite"))
        let readiness = await history.waitUntilReady()

        guard case .failed(let message) = readiness else {
            return XCTFail("Expected failed readiness, received \(readiness)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(history.fetchLast24Hours().isEmpty)
    }

    func testSaveAndFetchFailuresAreExposedAndLogged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-history-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 10)
        defer { try? FileManager.default.removeItem(at: directory) }

        let saveFailure = BatteryHistory(
            inMemory: true,
            diagnostics: log,
            storeOperations: BatteryHistoryStoreOperations(
                save: { _ in throw BatteryError.commandFailed("save", 1, "injected save failure") }
            )
        )
        let saveReadiness = await saveFailure.waitUntilReady()
        XCTAssertEqual(saveReadiness, .ready)
        saveFailure.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertTrue(saveFailure.saveError?.contains("injected save failure") == true)

        let fetchFailure = BatteryHistory(
            inMemory: true,
            diagnostics: log,
            storeOperations: BatteryHistoryStoreOperations(
                fetch: { _, _ in throw BatteryError.commandFailed("fetch", 1, "injected fetch failure") }
            )
        )
        let fetchReadiness = await fetchFailure.waitUntilReady()
        XCTAssertEqual(fetchReadiness, .ready)
        XCTAssertTrue(fetchFailure.fetchLast24Hours().isEmpty)
        XCTAssertTrue(fetchFailure.fetchError?.contains("injected fetch failure") == true)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if events.filter({ $0.category == .history }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.filter { $0.category == .history }.count, 2)
    }

    func testSuccessfulFetchClearsOnlyTheFetchError() async {
        var shouldFailFetch = true
        let history = BatteryHistory(
            inMemory: true,
            storeOperations: BatteryHistoryStoreOperations(
                fetch: { context, request in
                    if shouldFailFetch {
                        throw BatteryError.commandFailed("fetch", 1, "temporary fetch failure")
                    }
                    return try context.fetch(request)
                }
            )
        )
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)

        XCTAssertTrue(history.fetchLast24Hours().isEmpty)
        XCTAssertNotNil(history.fetchError)
        shouldFailFetch = false
        XCTAssertTrue(history.fetchLast24Hours().isEmpty)
        XCTAssertNil(history.fetchError)
    }
}

final class MagSafeLEDStateTests: XCTestCase {
    func testOnlyExplicitColorsHaveHardCodedValues() {
        XCTAssertEqual(MagSafeLEDState.green.rawValue, 0x03)
        XCTAssertEqual(MagSafeLEDState.orange.rawValue, 0x04)
    }

    func testNewerGenerationWinsWhenAnOlderWriteIsSlow() async throws {
        let backend = FakeChargeBackend()
        backend.setLEDDelay(0.2, for: .orange)
        let controller = MagSafeLEDController(backend: backend)

        await controller.apply(.solid(.orange), generation: 1) { _ in }
        try await Task.sleep(nanoseconds: 20_000_000)
        await controller.apply(.solid(.green), generation: 2) { _ in }
        try await Task.sleep(nanoseconds: 350_000_000)

        let writes = backend.operations.filter { $0.hasPrefix("set-led:") }
        XCTAssertEqual(writes, ["set-led:04", "set-led:03"])
        try await controller.shutdown(generation: 3)
    }
}
