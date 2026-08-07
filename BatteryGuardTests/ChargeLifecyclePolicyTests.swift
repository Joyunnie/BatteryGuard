import XCTest
@testable import BatteryGuard

final class ChargeLifecyclePolicyTests: XCTestCase {
    func testActiveLongRunningModesRestoreTheirRecordedMaintainLimit() throws {
        let topUp = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                ownership: .batteryGuard(lastLimit: 80),
                mode: .toppingUp(returnLimit: 75),
                effectiveLimit: 80
            )
        )
        let discharge = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                ownership: .batteryGuard(lastLimit: 80),
                mode: .discharging(target: 70, returnLimit: 65),
                effectiveLimit: 80
            )
        )

        XCTAssertEqual(topUp, .restoreMaintain(75))
        XCTAssertEqual(discharge, .restoreMaintain(65))
    }

    func testOwnershipAndHeatStatesTakePriorityOverGenericMaintainFallback() throws {
        let release = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                ownership: .releasing(lastLimit: 80),
                mode: .heatBlocked(previous: .maintaining(limit: 80)),
                effectiveLimit: 80
            )
        )
        let released = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                ownership: .system(lastLimit: 80),
                mode: .maintaining(limit: 80),
                effectiveLimit: 80
            )
        )
        let heatBlocked = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                ownership: .batteryGuard(lastLimit: 80),
                mode: .heatBlocked(previous: .maintaining(limit: 80)),
                effectiveLimit: 80
            )
        )

        XCTAssertEqual(release, .releaseControl)
        XCTAssertEqual(released, .preserveReleasedControl)
        XCTAssertEqual(heatBlocked, .keepChargingDisabled)
    }

    func testFailureDispositionCannotBeReinterpretedByShutdownPlanning() throws {
        let previous = RestorableChargeMode.maintaining(limit: 75)
        let heatFailure = ChargeMode.failed(
            previous: previous,
            message: "heat transition failed",
            disposition: .heatProtection
        )
        let uncertainFailure = ChargeMode.failed(
            previous: previous,
            message: "compensation failed",
            disposition: .manualIntervention
        )
        let recoverableFailure = ChargeMode.failed(
            previous: previous,
            message: "command failed before mutation",
            disposition: .recoverPrevious
        )

        XCTAssertEqual(
            try requestedPolicy(for: heatFailure),
            .keepChargingDisabled
        )
        XCTAssertThrowsError(try requestedPolicy(for: uncertainFailure)) { error in
            XCTAssertEqual(
                error as? ChargeShutdownPlanningError,
                .manualInterventionRequired("compensation failed")
            )
        }
        XCTAssertEqual(
            try requestedPolicy(for: recoverableFailure),
            .preserveMaintain
        )
    }

    func testShutdownRestoresMaintainWhenSleepPreparationIsActiveOrComplete() throws {
        let previous = RestorableChargeMode.toppingUp(returnLimit: 75)

        XCTAssertEqual(
            try requestedPolicy(
                for: .transitioning(.preparingForSleep(previous: previous))
            ),
            .restoreMaintain(75)
        )
        XCTAssertEqual(
            try requestedPolicy(for: .sleepProtected(previous: previous, charge: 70)),
            .restoreMaintain(75)
        )
    }

    func testUnsafeExternalStateIsRejectedBeforeShutdownMutation() {
        XCTAssertThrowsError(
            try ChargeShutdownPlanner.requestedPolicy(
                for: ChargeShutdownContext(
                    ownership: .batteryGuard(lastLimit: 80),
                    mode: .externalDrift(
                        expected: .maintaining(limit: 80),
                        observed: .discharging
                    ),
                    effectiveLimit: 80
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ChargeShutdownPlanningError,
                .unsafeExternalState(.discharging)
            )
        }
    }

    func testVerifiedPolicyPreservesOnlyCompleteMaintainTuple() throws {
        let verified = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: 75,
            maintainWorker: .running(pid: 7_575, target: 75)
        )
        let missingWorker = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: 75,
            maintainWorker: .stopped
        )

        XCTAssertEqual(
            try ChargeShutdownPlanner.verifiedPolicy(
                requested: .preserveMaintain,
                status: verified,
                restoreLimit: 80
            ),
            .preserveMaintain
        )
        XCTAssertEqual(
            try ChargeShutdownPlanner.verifiedPolicy(
                requested: .preserveMaintain,
                status: missingWorker,
                restoreLimit: 80
            ),
            .restoreMaintain(80)
        )
        XCTAssertEqual(
            try ChargeShutdownPlanner.verifiedPolicy(
                requested: .restoreMaintain(75),
                status: missingWorker,
                restoreLimit: 80
            ),
            .restoreMaintain(75)
        )
    }

    func testEveryTransitionFamilyHasAnExplicitShutdownPolicy() throws {
        let previous = RestorableChargeMode.maintaining(limit: 75)
        let cases: [(ChargeTransition, ChargeShutdownPolicy)] = [
            (.applyingMaintain(target: 60, previous: previous), .restoreMaintain(75)),
            (.startingTopUp(returnLimit: 70), .restoreMaintain(70)),
            (.stoppingTopUp(returnLimit: 70), .restoreMaintain(70)),
            (.startingDischarge(target: 60, returnLimit: 70), .restoreMaintain(70)),
            (.stoppingDischarge(returnLimit: 70), .restoreMaintain(70)),
            (.enteringHeat(previous: previous), .keepChargingDisabled),
            (.restoringHeat(previous: previous), .keepChargingDisabled),
            (.preparingForSleep(previous: previous), .restoreMaintain(75)),
            (.recoveringMaintain(limit: 65), .restoreMaintain(65)),
            (.releasingControl(previous: previous), .releaseControl)
        ]

        for (transition, expected) in cases {
            XCTAssertEqual(
                try ChargeShutdownPlanner.requestedPolicy(
                    for: ChargeShutdownContext(
                        ownership: .batteryGuard(lastLimit: 80),
                        mode: .transitioning(transition),
                        effectiveLimit: 80
                    )
                ),
                expected,
                "Unexpected shutdown policy for \(transition)"
            )
        }
    }

    func testReleasedControlRequiresACompatibleFreshTuple() throws {
        let released = BatteryControlStatus(
            charging: .enabled,
            isDischarging: false,
            maintainLevel: nil,
            maintainWorker: .stopped
        )
        let externalDischarge = BatteryControlStatus(
            charging: .enabled,
            isDischarging: true,
            maintainLevel: nil,
            maintainWorker: .stopped
        )

        XCTAssertEqual(
            try ChargeShutdownPlanner.verifiedPolicy(
                requested: .preserveReleasedControl,
                status: released,
                restoreLimit: 80
            ),
            .preserveReleasedControl
        )
        XCTAssertThrowsError(
            try ChargeShutdownPlanner.verifiedPolicy(
                requested: .preserveReleasedControl,
                status: externalDischarge,
                restoreLimit: 80
            )
        )
    }

    private func requestedPolicy(for mode: ChargeMode) throws -> ChargeShutdownPolicy {
        try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                ownership: .batteryGuard(lastLimit: 80),
                mode: mode,
                effectiveLimit: 80
            )
        )
    }

}
