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
            .finishAndRestoreMaintain(session)
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
            .finishAndRestoreMaintain(session)
        )
        XCTAssertEqual(
            LongRunningChargePolicy.progress(mode: session.expectedMode, currentCharge: 59),
            .finishAndRestoreMaintain(session)
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
            .recoverMaintain(session)
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

    func testEveryNonDisabledObservationBecomesReadOnlyDrift() {
        let session = LongRunningChargeSession.topUp(returnLimit: 70)
        let observations: [ObservedChargeMode] = [
            .maintaining(limit: 60),
            .charging,
            .discharging,
            .unavailable("status failed"),
            .inconsistent("conflicting tuple")
        ]

        for observed in observations {
            XCTAssertEqual(
                LongRunningChargePolicy.unexpectedExit(
                    session: session,
                    observed: observed
                ),
                .externalDrift(
                    expected: .maintaining(limit: 70),
                    observed: observed
                )
            )
        }
    }
}
