import XCTest
@testable import BatteryGuard

final class LongRunningChargePolicyTests: XCTestCase {
    func testInactiveModesNeverCreateLongRunningWork() {
        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: .maintaining(limit: 80), currentCharge: 80),
            .none
        )
        XCTAssertEqual(
            LongRunningChargePolicy.progress(
                mode: .transitioning(.startingTopUp(returnLimit: 80)),
                currentCharge: 70
            ),
            .none
        )
    }

    func testTopUpCompletesOnlyAtItsTarget() {
        let session = LongRunningChargeSession.topUp(returnLimit: 75)

        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 99),
            .checkLiveness(session)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 100),
            .complete(session)
        )
    }

    func testDischargeCompletesAtOrBelowItsRecordedTarget() {
        let session = LongRunningChargeSession.discharge(target: 60, returnLimit: 75)

        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 61),
            .checkLiveness(session)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 60),
            .complete(session)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 59),
            .complete(session)
        )
    }

    func testMissingOrInvalidChargeChecksLivenessInsteadOfInventingCompletion() {
        let session = LongRunningChargeSession.topUp(returnLimit: 80)

        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: nil),
            .checkLiveness(session)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 101),
            .checkLiveness(session)
        )
    }

    func testUnexpectedExitRecoversOnlyFromVerifiedChargingDisabled() {
        let session = LongRunningChargeSession.discharge(target: 60, returnLimit: 75)

        XCTAssertEqual(
            LongRunningChargePolicy.unexpectedExit(
                session: session,
                observed: .chargingDisabled
            ),
            .recoverMaintain(limit: 75)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.unexpectedExit(
                session: session,
                observed: .discharging
            ),
            .externalDrift(expected: .maintaining(limit: 75), observed: .discharging)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.unexpectedExit(
                session: session,
                observed: .unavailable("status failed")
            ),
            .externalDrift(
                expected: .maintaining(limit: 75),
                observed: .unavailable("status failed")
            )
        )
    }
}
