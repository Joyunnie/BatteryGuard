import XCTest
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

    func testIssueRegistryOrdersBySeverityThenRecency() {
        var registry = BatteryIssueRegistry()
        let start = Date(timeIntervalSince1970: 100)
        registry.set(.sensor, severity: .warning, message: "sensor", at: start)
        registry.set(.externalDrift, severity: .blocking, message: "drift", at: start.addingTimeInterval(1))
        registry.set(.command, severity: .critical, message: "command", at: start.addingTimeInterval(2))

        XCTAssertEqual(registry.orderedIssues.map(\.source), [.command, .externalDrift, .sensor])
    }

    func testIssueRegistryPreservesTimestampUntilTheMessageChanges() throws {
        var registry = BatteryIssueRegistry()
        let start = Date(timeIntervalSince1970: 100)
        registry.set(.sensor, severity: .warning, message: "same", at: start)
        registry.set(.sensor, severity: .warning, message: "same", at: start.addingTimeInterval(10))

        XCTAssertEqual(try XCTUnwrap(registry.orderedIssues.first).occurredAt, start)

        registry.set(.sensor, severity: .warning, message: "changed", at: start.addingTimeInterval(20))
        XCTAssertEqual(try XCTUnwrap(registry.orderedIssues.first).occurredAt, start.addingTimeInterval(20))
    }

    func testIssueRegistryHasDeterministicOrderingForExactTies() {
        var registry = BatteryIssueRegistry()
        let date = Date(timeIntervalSince1970: 100)
        registry.set(.sensor, severity: .warning, message: "sensor", at: date)
        registry.set(.led, severity: .warning, message: "led", at: date)

        XCTAssertEqual(registry.orderedIssues.map(\.source), [.led, .sensor])
    }
}
