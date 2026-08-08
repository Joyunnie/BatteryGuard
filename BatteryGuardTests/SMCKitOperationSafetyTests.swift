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

    func testBatteryTemperatureUsesBundledExactKeyReaderWhenAvailable() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-bundled-smc-reader-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf 'smc %s\n' "$*" >> \(shellQuote(commandLog.path))
            exit 9
            """
        )
        let readerFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo helper >> \(shellQuote(commandLog.path))
            echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)"
            echo "TB1T [flt ] 42.25 (bytes 00 00 29 42)"
            echo "TB2T [flt ] 39.0 (bytes 00 00 1c 42)"
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: readerFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: readerFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let temperature = try await backend.readBatteryTemperature()

        XCTAssertEqual(temperature, 42.25)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["helper"])
    }

    func testIncompleteBundledReaderFallsBackAndIsNotRetried() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-bundled-smc-reader-fallback-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf 'smc %s\n' "$*" >> \(shellQuote(commandLog.path))
            case "$*" in
              "-t") echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)" ;;
              "-k TB0T -r") echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)" ;;
              "-k TB1T -r") echo "TB1T [flt ] 42.25 (bytes 00 00 29 42)" ;;
              "-k TB2T -r") echo "TB2T [flt ] 39.0 (bytes 00 00 1c 42)" ;;
            esac
            """
        )
        let readerFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo helper >> \(shellQuote(commandLog.path))
            echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)"
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: readerFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: readerFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let firstTemperature = try await backend.readBatteryTemperature()
        let secondTemperature = try await backend.readBatteryTemperature()

        XCTAssertEqual(firstTemperature, 42.25)
        XCTAssertEqual(secondTemperature, 42.25)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(
            commands,
            [
                "helper",
                "smc -t",
                "smc -k TB0T -r", "smc -k TB1T -r", "smc -k TB2T -r",
                "smc -k TB0T -r", "smc -k TB1T -r", "smc -k TB2T -r"
            ]
        )
    }

    func testFailedBundledReaderFallsBackAndIsNotRetried() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-failed-smc-reader-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf 'smc %s\n' "$*" >> \(shellQuote(commandLog.path))
            echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)"
            echo "TB1T [flt ] 42.25 (bytes 00 00 29 42)"
            echo "TB2T [flt ] 39.0 (bytes 00 00 1c 42)"
            """
        )
        let readerFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo helper >> \(shellQuote(commandLog.path))
            exit 9
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: readerFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: readerFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let firstTemperature = try await backend.readBatteryTemperature()
        let secondTemperature = try await backend.readBatteryTemperature()
        XCTAssertEqual(firstTemperature, 42.25)
        XCTAssertEqual(secondTemperature, 42.25)

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["helper", "smc -t", "smc -t"])
    }

    func testMissingBundledReaderDegradesToExternalSMC() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-missing-smc-reader-\(UUID().uuidString).log")
        let missingReader = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-missing-reader-\(UUID().uuidString)")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf 'smc %s\n' "$*" >> \(shellQuote(commandLog.path))
            echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)"
            echo "TB1T [flt ] 42.25 (bytes 00 00 29 42)"
            echo "TB2T [flt ] 39.0 (bytes 00 00 1c 42)"
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: missingReader.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let temperature = try await backend.readBatteryTemperature()

        XCTAssertEqual(temperature, 42.25)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["smc -t"])
    }

    func testBundledReaderTimeoutFailsClosedWithoutExternalFallback() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-timeout-smc-reader-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo smc >> \(shellQuote(commandLog.path))
            exit 9
            """
        )
        let readerFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo helper >> \(shellQuote(commandLog.path))
            sleep 10
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: readerFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: readerFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        do {
            _ = try await backend.readBatteryTemperature()
            XCTFail("Expected the bundled reader timeout to fail closed")
        } catch let error as BatteryError {
            guard case .commandTimedOut = error else {
                return XCTFail("Expected commandTimedOut, got \(error)")
            }
        }

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["helper"])
    }

    func testBundledReaderCancellationStopsWithoutExternalFallback() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-cancelled-smc-reader-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo smc >> \(shellQuote(commandLog.path))
            exit 9
            """
        )
        let readerFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo helper >> \(shellQuote(commandLog.path))
            sleep 10
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: readerFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: readerFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let operation = Task { try await backend.readBatteryTemperature() }
        let helperStarted = await eventually {
            FileManager.default.fileExists(atPath: commandLog.path)
        }
        XCTAssertTrue(helperStarted)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected the bundled reader cancellation to propagate")
        } catch let error as BatteryError {
            guard case .commandCancelled = error else {
                return XCTFail("Expected commandCancelled, got \(error)")
            }
        }

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["helper"])
    }

    func testPerKeyFallbackRespectsAggregateSafetyDeadline() async throws {
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "-t" ]]; then
              echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)"
              exit 0
            fi
            sleep 10
            """
        )
        let readerFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            echo "TB0T [flt ] 31.5 (bytes 00 00 fc 41)"
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: readerFixture)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            temperatureReaderPath: readerFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let startedAt = Date()
        do {
            _ = try await backend.readBatteryTemperature()
            XCTFail("Expected all per-key reads to time out")
        } catch let error as BatteryError {
            guard case .commandFailed = error else {
                return XCTFail("Expected commandFailed, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5.25)
    }

    func testBatteryTemperatureUsesOneBatchedSMCInvocation() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-smc-temperature-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf '%s\n' "$*" >> \(shellQuote(commandLog.path))
            if [[ "$1" == "-t" ]]; then
              echo "TB0T  [sp78]  31.5 (bytes 1f 80)"
              echo "TB1T  [sp78]  42.25 (bytes 2a 40)"
              echo "TB2T  [sp78]  39.0 (bytes 27 00)"
              echo "TC0P  [sp78]  99.0 (bytes 63 00)"
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let temperature = try await backend.readBatteryTemperature()

        XCTAssertEqual(temperature, 42.25)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["-t"])
    }

    func testBatteryTemperatureListIgnoresUnrelatedAndInvalidSensors() {
        XCTAssertEqual(
            SMCKit.parseBatteryTemperatureList(
                """
                TC0P  [sp78]  99.0 (bytes 63 00)
                TB0T  [sp78]  invalid (bytes 00 00)
                TB2T  [sp78]  37.75 (bytes 25 c0)
                """
            ),
            37.75
        )
        XCTAssertNil(SMCKit.parseBatteryTemperatureList("TC0P [sp78] 40.0 (bytes 28 00)"))
    }

    func testBatteryTemperatureFallsBackForPartialBatchAndCachesThatContract() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-smc-temperature-fallback-\(UUID().uuidString).log")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf '%s\n' "$*" >> \(shellQuote(commandLog.path))
            case "$*" in
              "-t") echo "TB0T [sp78] 31.5 (bytes 1f 80)" ;;
              "-k TB0T -r") echo "TB0T [sp78] 31.5 (bytes 1f 80)" ;;
              "-k TB1T -r") echo "TB1T [sp78] 42.25 (bytes 2a 40)" ;;
              "-k TB2T -r") echo "TB2T [sp78] 39.0 (bytes 27 00)" ;;
            esac
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: commandLog)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        try await backend.open()
        let firstTemperature = try await backend.readBatteryTemperature()
        let secondTemperature = try await backend.readBatteryTemperature()

        XCTAssertEqual(firstTemperature, 42.25)
        XCTAssertEqual(secondTemperature, 42.25)
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(
            commands,
            [
                "-t",
                "-k TB0T -r", "-k TB1T -r", "-k TB2T -r",
                "-k TB0T -r", "-k TB1T -r", "-k TB2T -r"
            ]
        )
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
