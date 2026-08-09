import XCTest
import Foundation
@testable import BatteryGuard


@MainActor
final class BatteryHistoryTests: XCTestCase {
    func testHistoryUsesInMemoryStoreAndDeduplicates() async {
        let history = BatteryHistory(inMemory: true)
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)
        history.record(chargePercent: 80, chargeLimit: 80)
        history.record(chargePercent: 80, chargeLimit: 80)

        let records = history.fetchRecentHistory()
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
        XCTAssertEqual(history.fetchRecentHistory().count, 1)

        clock.advance(by: 2)
        history.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertEqual(history.fetchRecentHistory().count, 2)
    }

    func testRecentHistoryIncludesSevenDaysAndExcludesOlderRecords() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let history = BatteryHistory(inMemory: true, now: { clock.now() })
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)

        history.record(chargePercent: 40, chargeLimit: 80)
        clock.advance(by: BatteryHistory.retentionInterval - 60)
        history.record(chargePercent: 50, chargeLimit: 80)
        XCTAssertEqual(history.fetchRecentHistory().map(\.chargePercent), [40, 50])

        clock.advance(by: 2 * 60)
        history.record(chargePercent: 60, chargeLimit: 80)
        XCTAssertEqual(history.fetchRecentHistory().map(\.chargePercent), [50, 60])
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

    func testDownsamplingPreservesAOneSampleExtreme() {
        var records = (0..<1_000).map {
            BatteryHistory.ChartRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                chargePercent: 50,
                chargeLimit: 80
            )
        }
        records[501] = BatteryHistory.ChartRecord(
            timestamp: records[501].timestamp,
            chargePercent: 100,
            chargeLimit: 80
        )

        let sampled = BatteryHistory.downsample(records, maxPoints: 100)

        XCTAssertTrue(sampled.contains { $0.chargePercent == 100 })
    }

    func testDownsamplingPreservesAOneSampleChargeLimitExtreme() {
        var records = (0..<1_000).map {
            BatteryHistory.ChartRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                chargePercent: 50,
                chargeLimit: 80
            )
        }
        records[501] = BatteryHistory.ChartRecord(
            timestamp: records[501].timestamp,
            chargePercent: 50,
            chargeLimit: 60
        )

        let sampled = BatteryHistory.downsample(records, maxPoints: 100)

        XCTAssertTrue(sampled.contains { $0.chargeLimit == 60 })
    }

    func testDownsamplingPreservesDistinctExtremaFromBothSeriesInTheSameBucket() {
        var records = (0..<1_000).map {
            BatteryHistory.ChartRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                chargePercent: 50,
                chargeLimit: 80
            )
        }
        records[501] = BatteryHistory.ChartRecord(
            timestamp: records[501].timestamp,
            chargePercent: 100,
            chargeLimit: 80
        )
        records[502] = BatteryHistory.ChartRecord(
            timestamp: records[502].timestamp,
            chargePercent: 50,
            chargeLimit: 60
        )

        let sampled = BatteryHistory.downsample(records, maxPoints: 100)

        XCTAssertEqual(sampled.count, 100)
        XCTAssertTrue(sampled.contains { $0.timestamp == records[501].timestamp })
        XCTAssertTrue(sampled.contains { $0.timestamp == records[502].timestamp })
    }

    func testDownsamplingWithInsufficientBudgetKeepsEndpointsThenChargeExtreme() {
        var records = (0..<10).map {
            BatteryHistory.ChartRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                chargePercent: 50,
                chargeLimit: 80
            )
        }
        records[4] = BatteryHistory.ChartRecord(
            timestamp: records[4].timestamp,
            chargePercent: 100,
            chargeLimit: 80
        )
        records[5] = BatteryHistory.ChartRecord(
            timestamp: records[5].timestamp,
            chargePercent: 50,
            chargeLimit: 60
        )

        let sampled = BatteryHistory.downsample(records, maxPoints: 3)

        XCTAssertEqual(sampled, [records[0], records[4], records[9]])
    }

    func testTimelineDownsamplingPreservesDailyResolution() {
        let day: TimeInterval = 24 * 60 * 60
        let domainEnd = Date(timeIntervalSince1970: 8 * day)
        let records = (0..<(7 * 96)).map { index in
            BatteryHistory.ChartRecord(
                timestamp: domainEnd.addingTimeInterval(-7 * day + TimeInterval(index) * 15 * 60),
                chargePercent: index % 101,
                chargeLimit: 80
            )
        }

        let sampled = BatteryHistory.downsampleTimeline(
            records,
            domainEnd: domainEnd,
            interval: day,
            maxPointsPerInterval: 120
        )

        XCTAssertEqual(sampled, records)
    }

    func testTimelineDownsamplingCapsEachDayIndependently() {
        let day: TimeInterval = 24 * 60 * 60
        let domainEnd = Date(timeIntervalSince1970: 8 * day)
        let records = (0..<(2 * 240)).map { index in
            BatteryHistory.ChartRecord(
                timestamp: domainEnd.addingTimeInterval(-2 * day + TimeInterval(index) * 6 * 60),
                chargePercent: index % 101,
                chargeLimit: index % 2 == 0 ? 80 : 75
            )
        }

        let sampled = BatteryHistory.downsampleTimeline(
            records,
            domainEnd: domainEnd,
            interval: day,
            maxPointsPerInterval: 120
        )

        XCTAssertEqual(sampled.count, 240)
        XCTAssertEqual(sampled.first?.timestamp, records.first?.timestamp)
        XCTAssertEqual(sampled.last?.timestamp, records.last?.timestamp)
    }

    func testHistoryViewportStartsAtAndFollowsTheLiveDay() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 10 * day)
        var viewport = BatteryHistoryViewport(now: start)

        XCTAssertEqual(viewport.scrollPosition, start.addingTimeInterval(-day))
        viewport.refresh(now: start.addingTimeInterval(60))

        XCTAssertTrue(viewport.isInitialized)
        XCTAssertEqual(viewport.domainEnd, start.addingTimeInterval(60))
        XCTAssertEqual(viewport.scrollPosition, start.addingTimeInterval(-day + 60))
    }

    func testHistoryViewportPreservesAUserSelectedPastDayOnRefresh() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 10 * day)
        var viewport = BatteryHistoryViewport(now: start)
        viewport.refresh(now: start)
        let pastPosition = start.addingTimeInterval(-3 * day)
        viewport.scrollPosition = pastPosition

        viewport.refresh(now: start.addingTimeInterval(60))

        XCTAssertEqual(viewport.domainEnd, start.addingTimeInterval(60))
        XCTAssertEqual(viewport.scrollPosition, pastPosition)
    }

    func testHistoryViewportTreatsNearLivePositionAsFollowing() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 10 * day)
        var viewport = BatteryHistoryViewport(now: start)
        viewport.refresh(now: start)
        viewport.scrollPosition = start.addingTimeInterval(-day - 90)

        viewport.refresh(now: start.addingTimeInterval(60))

        XCTAssertEqual(viewport.scrollPosition, start.addingTimeInterval(-day + 60))
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
        XCTAssertTrue(history.fetchRecentHistory().isEmpty)
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
        XCTAssertTrue(fetchFailure.fetchRecentHistory().isEmpty)
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

        XCTAssertTrue(history.fetchRecentHistory().isEmpty)
        XCTAssertNotNil(history.fetchError)
        shouldFailFetch = false
        XCTAssertTrue(history.fetchRecentHistory().isEmpty)
        XCTAssertNil(history.fetchError)
    }
}
