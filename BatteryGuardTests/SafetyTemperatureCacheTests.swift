import XCTest
import Foundation
@testable import BatteryGuard

final class SafetyTemperatureCacheTests: XCTestCase {
    func testRejectsExpiredAndFutureSamples() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        var cache = SafetyTemperatureCache()
        cache.record(31.5, at: recordedAt)

        XCTAssertEqual(cache.recentValue(at: recordedAt.addingTimeInterval(15), maxAge: 15), 31.5)
        XCTAssertNil(cache.recentValue(at: recordedAt.addingTimeInterval(15.001), maxAge: 15))
        XCTAssertNil(cache.recentValue(at: recordedAt.addingTimeInterval(-1), maxAge: 15))
        XCTAssertNil(cache.recentValue(at: recordedAt, maxAge: .infinity))
    }

    func testSamplingBecomesDueAtTheExactIntervalBoundary() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        var cache = SafetyTemperatureCache()
        cache.record(31.5, at: recordedAt)

        XCTAssertFalse(cache.isSamplingDue(
            at: recordedAt.addingTimeInterval(4.999),
            interval: 5
        ))
        XCTAssertTrue(cache.isSamplingDue(
            at: recordedAt.addingTimeInterval(5),
            interval: 5
        ))
        XCTAssertTrue(cache.isSamplingDue(
            at: recordedAt.addingTimeInterval(5.001),
            interval: 5
        ))
    }

    func testInvalidRecordClearsAnEarlierValidSample() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        var cache = SafetyTemperatureCache()
        let invalidSamples = [Double.nan, .infinity, 200]

        for invalidSample in invalidSamples {
            cache.record(31.5, at: recordedAt)
            cache.record(invalidSample, at: recordedAt)
            XCTAssertNil(cache.recentValue(at: recordedAt, maxAge: 15))
        }

        cache.record(31.5, at: Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertNil(cache.recentValue(at: recordedAt, maxAge: 15))
    }

    func testClearRemovesValueAndTimestampTogether() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        var cache = SafetyTemperatureCache()
        cache.record(31.5, at: recordedAt)

        cache.clear()

        XCTAssertNil(cache.value)
        XCTAssertNil(cache.recordedAt)
        XCTAssertNil(cache.recentValue(at: recordedAt, maxAge: 15))
    }
}
