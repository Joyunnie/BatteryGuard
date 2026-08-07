import XCTest
import ServiceManagement
import Combine
import Darwin
import AppKit
@testable import BatteryGuard


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

