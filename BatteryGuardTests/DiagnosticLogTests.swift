import XCTest
import Foundation
@testable import BatteryGuard


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

    func testOversizedDiagnosticFileIsRejectedWithoutLoadingIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-large-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x20, count: 1_048_577).write(to: fileURL)
        let log = DiagnosticLog(fileURL: fileURL, capacity: 10)

        let events = await log.recentEvents()
        let persistenceError = await log.persistenceError

        XCTAssertTrue(events.isEmpty)
        XCTAssertNotNil(persistenceError)
    }

    func testDiagnosticSymlinkIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-symlink-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("Diagnostics.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: link, capacity: 10)

        let events = await log.recentEvents()
        let persistenceError = await log.persistenceError
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotNil(persistenceError)
    }

    func testDiagnosticLogDropsOldestEventsToRemainWithinByteLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-bounded-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: fileURL, capacity: 100)

        for index in 0..<100 {
            await log.record(
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    category: .control,
                    operation: "operation-\(index)-" + String(repeating: "x", count: 20_000)
                )
            )
        }

        let events = await log.recentEvents()
        let persistenceError = await log.persistenceError
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? NSNumber).intValue

        XCTAssertLessThan(events.count, 100)
        XCTAssertTrue(events.last?.operation.hasPrefix("operation-99-") == true)
        XCTAssertLessThanOrEqual(fileSize, 1_048_576)
        XCTAssertNil(persistenceError)
    }

    func testDiagnosticLogTightensExistingDirectoryPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-diagnostic-permissions-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: fileURL, capacity: 10)

        await log.record(DiagnosticEvent(category: .control, operation: "permission check"))

        let persistenceError = await log.persistenceError
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o700)
        XCTAssertNil(persistenceError)
    }
}
