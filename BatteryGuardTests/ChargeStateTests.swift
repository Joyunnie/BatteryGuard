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

    func testPowerTransitionPresentationIsNeutralAndNeverShowsChargingBolt() {
        let presentation = BatteryPresentation.make(
            info: makeBatteryInfo(isCharging: true),
            connection: .transitioning(previous: .disconnected),
            mode: .maintaining(limit: 80),
            chargeState: .charging,
            requiresManualRecovery: false
        )

        XCTAssertEqual(presentation.statusTitle, "전원 연결 상태 확인 중")
        XCTAssertEqual(presentation.powerLabel, "확인 중")
        XCTAssertEqual(presentation.menuBarIcon, "arrow.triangle.2.circlepath")
        XCTAssertFalse(presentation.showsChargingBolt)
    }

    func testUncertainConnectionNeverReusesPreviousConnectionAsFact() {
        let presentation = BatteryPresentation.make(
            info: makeBatteryInfo(isPluggedIn: true),
            connection: .uncertain(previous: .connected),
            mode: .maintaining(limit: 80),
            chargeState: .chargingPaused,
            requiresManualRecovery: false
        )

        XCTAssertEqual(presentation.statusTitle, "전원 연결 상태 확인 필요")
        XCTAssertEqual(presentation.powerLabel, "알 수 없음")
        XCTAssertEqual(presentation.eyebrow, "전원 연결 불명")
    }

    func testConnectedButNotChargingBelowLimitIsPresentedAsWaiting() {
        let presentation = BatteryPresentation.make(
            info: makeBatteryInfo(charge: 60, isCharging: false),
            connection: .stable(.connected),
            mode: .maintaining(limit: 80),
            chargeState: .chargingPaused,
            requiresManualRecovery: false
        )

        XCTAssertEqual(presentation.statusTitle, "전원 연결됨 · 충전 대기 중")
        XCTAssertEqual(presentation.headline, "macOS의 충전 시작을 기다리고 있어요")
        XCTAssertFalse(presentation.showsChargingBolt)
    }

    func testMaintainAtLimitIsDistinctFromWaitingBelowLimit() {
        let presentation = BatteryPresentation.make(
            info: makeBatteryInfo(charge: 80, isCharging: false),
            connection: .stable(.connected),
            mode: .maintaining(limit: 80),
            chargeState: .chargingPaused,
            requiresManualRecovery: false
        )

        XCTAssertEqual(presentation.statusTitle, "충전 한도 유지 중")
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertFalse(presentation.showsChargingBolt)
    }

    func testChargingBoltRequiresChargingMeasurementOrExplicitTopUp() {
        let charging = BatteryPresentation.make(
            info: makeBatteryInfo(isCharging: true),
            connection: .stable(.connected),
            mode: .maintaining(limit: 80),
            chargeState: .charging,
            requiresManualRecovery: false
        )
        let topUp = BatteryPresentation.make(
            info: makeBatteryInfo(isCharging: false),
            connection: .stable(.connected),
            mode: .toppingUp(returnLimit: 80),
            chargeState: .topUp,
            requiresManualRecovery: false
        )

        XCTAssertTrue(charging.showsChargingBolt)
        XCTAssertTrue(topUp.showsChargingBolt)
    }

    func testManualRecoveryUsesOneTransitionAwareTitleContract() {
        let expectations: [(PowerConnectionObservation, String, String)] = [
            (.stable(.connected), "전원 연결됨 · 충전 제어 복구 필요", "연결됨"),
            (.transitioning(previous: .connected), "충전 제어 복구 필요", "확인 중"),
            (.uncertain(previous: .connected), "충전 제어 복구 필요", "알 수 없음"),
            (.stable(.disconnected), "충전 제어 복구 필요", "연결 안 됨")
        ]

        for (connection, expectedTitle, expectedPowerLabel) in expectations {
            let presentation = BatteryPresentation.make(
                info: makeBatteryInfo(),
                connection: connection,
                mode: .maintaining(limit: 80),
                chargeState: .chargingPaused,
                requiresManualRecovery: true
            )

            XCTAssertEqual(presentation.statusTitle, expectedTitle)
            XCTAssertEqual(presentation.statusIcon, "exclamationmark.triangle.fill")
            XCTAssertEqual(presentation.tone, .danger)
            XCTAssertEqual(presentation.powerLabel, expectedPowerLabel)
        }
    }

    func testSafetyModesRemainVisibleDuringPowerObservationChanges() {
        let heat = BatteryPresentation.make(
            info: makeBatteryInfo(),
            connection: .transitioning(previous: .connected),
            mode: .heatBlocked(previous: .maintaining(limit: 80)),
            chargeState: .chargingPaused,
            requiresManualRecovery: false
        )
        let sleep = BatteryPresentation.make(
            info: makeBatteryInfo(),
            connection: .uncertain(previous: .connected),
            mode: .sleepProtected(previous: .maintaining(limit: 80), charge: 80),
            chargeState: .chargingPaused,
            requiresManualRecovery: false
        )
        let drift = BatteryPresentation.make(
            info: makeBatteryInfo(),
            connection: .transitioning(previous: .connected),
            mode: .externalDrift(
                expected: .maintaining(limit: 80),
                observed: .chargingDisabled
            ),
            chargeState: .unknown,
            requiresManualRecovery: false
        )
        let failure = BatteryPresentation.make(
            info: makeBatteryInfo(),
            connection: .transitioning(previous: .connected),
            mode: .failed(
                previous: .maintaining(limit: 80),
                message: "test failure",
                disposition: .recoverPrevious
            ),
            chargeState: .unknown,
            requiresManualRecovery: false
        )

        XCTAssertEqual(heat.statusTitle, "고온 보호 중")
        XCTAssertEqual(sleep.statusTitle, "잠자기 충전 보호 중")
        XCTAssertEqual(drift.statusTitle, "외부 충전 상태 확인 필요")
        XCTAssertEqual(failure.statusTitle, "충전 제어 확인 필요")
        XCTAssertFalse(heat.showsChargingBolt)
        XCTAssertFalse(sleep.showsChargingBolt)
        XCTAssertFalse(drift.showsChargingBolt)
        XCTAssertFalse(failure.showsChargingBolt)
    }

    func testDisconnectedPresentationUsesBatteryPowerLanguage() {
        let presentation = BatteryPresentation.make(
            info: makeBatteryInfo(isPluggedIn: false),
            connection: .stable(.disconnected),
            mode: .maintaining(limit: 80),
            chargeState: .notConnected,
            requiresManualRecovery: false
        )

        XCTAssertEqual(presentation.statusTitle, "전원 미연결")
        XCTAssertEqual(presentation.powerLabel, "연결 안 됨")
        XCTAssertEqual(presentation.headline, "배터리 전원으로 사용 중이에요")
        XCTAssertEqual(presentation.tone, .neutral)
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
