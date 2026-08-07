import XCTest
import ServiceManagement
import Combine
import Darwin
import AppKit
@testable import BatteryGuard


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

