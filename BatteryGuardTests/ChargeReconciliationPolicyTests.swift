import XCTest
@testable import BatteryGuard

final class ChargeReconciliationPolicyTests: XCTestCase {
    private let releasedStatus = BatteryControlStatus(
        charging: .disabled,
        isDischarging: false,
        maintainLevel: 80,
        maintainWorker: .stopped
    )

    func testPendingReleaseNeverMatchesReadOnlyStatus() {
        for observation in observations {
            XCTAssertFalse(
                matches(
                    releasedStatus,
                    ownership: observation,
                    expectation: .controlReleasing(lastLimit: 80)
                )
            )
        }
    }

    func testReleasedControlRequiresConfirmedInactiveOwnership() {
        XCTAssertTrue(
            matches(
                releasedStatus,
                ownership: .inactive,
                expectation: .controlReleased(lastLimit: 80)
            )
        )
        XCTAssertFalse(
            matches(
                releasedStatus,
                ownership: .active,
                expectation: .controlReleased(lastLimit: 80)
            )
        )
        XCTAssertFalse(
            matches(
                releasedStatus,
                ownership: .notRequired,
                expectation: .controlReleased(lastLimit: 80)
            )
        )
    }

    func testReleasedControlRejectsUnknownOrUnsafeCLIState() {
        let incompatibleStatuses = [
            BatteryControlStatus(
                charging: .unknown,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .stopped
            ),
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: true,
                maintainLevel: 80,
                maintainWorker: .stopped
            ),
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 80, target: 80)
            )
        ]

        for status in incompatibleStatuses {
            XCTAssertFalse(
                matches(
                    status,
                    ownership: .inactive,
                    expectation: .controlReleased(lastLimit: 80)
                )
            )
        }
    }

    func testTopUpRequiresOwnedOperationAndCompleteTuple() {
        let expectation = ReconciledChargeExpectation.toppingUp(returnLimit: 80)
        let valid = BatteryControlStatus(
            charging: .enabled,
            isDischarging: false,
            maintainLevel: 80,
            maintainWorker: .stopped
        )
        XCTAssertTrue(matches(valid, ownership: .active, expectation: expectation))
        XCTAssertFalse(matches(valid, ownership: .inactive, expectation: expectation))
        XCTAssertFalse(matches(valid, ownership: .notRequired, expectation: expectation))

        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                ),
                ownership: .active,
                expectation: expectation
            )
        )
        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .enabled,
                    isDischarging: true,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                ),
                ownership: .active,
                expectation: expectation
            )
        )
        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .enabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: .running(pid: 80, target: 80)
                ),
                ownership: .active,
                expectation: expectation
            )
        )
    }

    func testDischargeRequiresOwnedOperationAndCompleteTuple() {
        let expectation = ReconciledChargeExpectation.discharging(target: 65, returnLimit: 80)
        let valid = BatteryControlStatus(
            charging: .enabled,
            isDischarging: true,
            maintainLevel: 80,
            maintainWorker: .stopped
        )
        XCTAssertTrue(matches(valid, ownership: .active, expectation: expectation))
        XCTAssertFalse(matches(valid, ownership: .inactive, expectation: expectation))
        XCTAssertFalse(matches(valid, ownership: .notRequired, expectation: expectation))

        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: true,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                ),
                ownership: .active,
                expectation: expectation
            )
        )
        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                ),
                ownership: .active,
                expectation: expectation
            )
        )
        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .enabled,
                    isDischarging: true,
                    maintainLevel: 80,
                    maintainWorker: .duplicate(pids: [80, 81])
                ),
                ownership: .active,
                expectation: expectation
            )
        )
    }

    func testMaintainRequiresExactLiveWorkerTuple() {
        let expectation = ReconciledChargeExpectation.maintaining(limit: 75)
        let verified = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: 75,
            maintainWorker: .running(pid: 75, target: 75)
        )
        XCTAssertTrue(matches(verified, expectation: expectation))

        let invalidWorkers: [MaintainWorkerStatus] = [
            .running(pid: 75, target: 80),
            .stopped,
            .stale(pid: 75),
            .duplicate(pids: [75, 76]),
            .unknown
        ]
        for worker in invalidWorkers {
            XCTAssertFalse(
                matches(
                    BatteryControlStatus(
                        charging: .disabled,
                        isDischarging: false,
                        maintainLevel: 75,
                        maintainWorker: worker
                    ),
                    expectation: expectation
                )
            )
        }
    }

    func testChargingDisabledRequiresVerifiedStoppedTuple() {
        let expectation = ReconciledChargeExpectation.chargingDisabled(
            previous: .maintaining(limit: 80)
        )
        XCTAssertTrue(matches(releasedStatus, expectation: expectation))
        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: nil,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                ),
                expectation: expectation
            )
        )
        XCTAssertFalse(
            matches(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: .stale(pid: 80)
                ),
                expectation: expectation
            )
        )
    }

    func testObservedModeClassifiesEverySupportedTuple() {
        XCTAssertEqual(
            ChargeReconciliationPolicy.observedMode(
                from: BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: false,
                    maintainLevel: 75,
                    maintainWorker: .running(pid: 75, target: 75)
                )
            ),
            .maintaining(limit: 75)
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.observedMode(
                from: BatteryControlStatus(
                    charging: .enabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                )
            ),
            .charging
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.observedMode(
                from: BatteryControlStatus(
                    charging: .enabled,
                    isDischarging: true,
                    maintainLevel: 80,
                    maintainWorker: .stopped
                )
            ),
            .discharging
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.observedMode(from: releasedStatus),
            .chargingDisabled
        )
    }

    func testObservedModeRejectsInconsistentAndOutOfRangeMaintainTuples() {
        let inconsistent = BatteryControlStatus(
            charging: .unknown,
            isDischarging: nil,
            maintainLevel: 80,
            maintainWorker: .unknown
        )
        let outOfRange = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: 101,
            maintainWorker: .running(pid: 101, target: 101)
        )

        guard case .inconsistent = ChargeReconciliationPolicy.observedMode(from: inconsistent) else {
            return XCTFail("Expected an inconsistent unknown tuple")
        }
        guard case .inconsistent = ChargeReconciliationPolicy.observedMode(from: outOfRange) else {
            return XCTFail("Expected an out-of-range maintain tuple to be inconsistent")
        }
    }

    func testEveryExpectationMapsToItsReconciledMode() {
        let maintaining = ReconciledChargeExpectation.maintaining(limit: 75)
        let toppingUp = ReconciledChargeExpectation.toppingUp(returnLimit: 80)
        let discharging = ReconciledChargeExpectation.discharging(target: 65, returnLimit: 80)
        let blocked = ReconciledChargeExpectation.chargingDisabled(
            previous: .maintaining(limit: 80)
        )
        let released = ReconciledChargeExpectation.controlReleased(lastLimit: 80)
        let releasing = ReconciledChargeExpectation.controlReleasing(lastLimit: 80)

        XCTAssertEqual(maintaining.reconciledMode, .maintaining(limit: 75))
        XCTAssertEqual(toppingUp.reconciledMode, .toppingUp(returnLimit: 80))
        XCTAssertEqual(discharging.reconciledMode, .discharging(target: 65, returnLimit: 80))
        XCTAssertEqual(blocked.reconciledMode, .heatBlocked(previous: .maintaining(limit: 80)))
        XCTAssertEqual(released.reconciledMode, .controlDisabled(lastLimit: 80))
        XCTAssertEqual(
            releasing.reconciledMode,
            .externalDrift(
                expected: releasing,
                observed: .unavailable("BatteryGuard control release is still pending")
            )
        )
    }

    func testEveryRestorableModeMapsToItsExpectation() {
        XCTAssertEqual(
            ChargeReconciliationPolicy.expectation(from: .maintaining(limit: 75)),
            .maintaining(limit: 75)
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.expectation(from: .toppingUp(returnLimit: 80)),
            .toppingUp(returnLimit: 80)
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.expectation(
                from: .discharging(target: 65, returnLimit: 80)
            ),
            .discharging(target: 65, returnLimit: 80)
        )
    }

    func testActiveModeExpectationAcceptsOnlyActiveModes() {
        XCTAssertEqual(
            ChargeReconciliationPolicy.expectation(fromActiveMode: .maintaining(limit: 75)),
            .maintaining(limit: 75)
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.expectation(fromActiveMode: .toppingUp(returnLimit: 80)),
            .toppingUp(returnLimit: 80)
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.expectation(
                fromActiveMode: .discharging(target: 65, returnLimit: 80)
            ),
            .discharging(target: 65, returnLimit: 80)
        )

        let inactiveModes: [ChargeMode] = [
            .idle,
            .heatBlocked(previous: .maintaining(limit: 80)),
            .controlDisabled(lastLimit: 80),
            .transitioning(.startingTopUp(returnLimit: 80)),
            .externalDrift(
                expected: .controlReleased(lastLimit: 80),
                observed: .charging
            ),
            .failed(previous: .maintaining(limit: 80), message: "failed", controlsBlocked: false)
        ]
        for mode in inactiveModes {
            XCTAssertNil(ChargeReconciliationPolicy.expectation(fromActiveMode: mode))
        }
    }

    private var observations: [OwnedLongRunningOperationObservation] {
        [.notRequired, .active, .inactive]
    }

    private func matches(
        _ status: BatteryControlStatus,
        ownership: OwnedLongRunningOperationObservation = .notRequired,
        expectation: ReconciledChargeExpectation
    ) -> Bool {
        ChargeReconciliationPolicy.status(
            ChargeReconciliationSnapshot(
                status: status,
                ownedLongRunningOperation: ownership
            ),
            matches: expectation
        )
    }
}
