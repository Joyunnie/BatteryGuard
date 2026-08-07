import XCTest
import Foundation
import Darwin
@testable import BatteryGuard


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
