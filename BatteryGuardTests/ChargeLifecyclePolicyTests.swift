import XCTest
@testable import BatteryGuard

final class ChargeLifecyclePolicyTests: XCTestCase {
    func testActiveLongRunningModesRestoreTheirRecordedMaintainLimit() throws {
        let topUp = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                releasePending: false,
                controlEnabled: true,
                mode: .toppingUp(returnLimit: 75),
                effectiveLimit: 80
            )
        )
        let discharge = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                releasePending: false,
                controlEnabled: true,
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
                releasePending: true,
                controlEnabled: false,
                mode: .heatBlocked(previous: .maintaining(limit: 80)),
                effectiveLimit: 80
            )
        )
        let released = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                releasePending: false,
                controlEnabled: false,
                mode: .maintaining(limit: 80),
                effectiveLimit: 80
            )
        )
        let heatBlocked = try ChargeShutdownPlanner.requestedPolicy(
            for: ChargeShutdownContext(
                releasePending: false,
                controlEnabled: true,
                mode: .heatBlocked(previous: .maintaining(limit: 80)),
                effectiveLimit: 80
            )
        )

        XCTAssertEqual(release, .releaseControl)
        XCTAssertEqual(released, .preserveReleasedControl)
        XCTAssertEqual(heatBlocked, .keepChargingDisabled)
    }

    func testUnsafeExternalStateIsRejectedBeforeShutdownMutation() {
        XCTAssertThrowsError(
            try ChargeShutdownPlanner.requestedPolicy(
                for: ChargeShutdownContext(
                    releasePending: false,
                    controlEnabled: true,
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

    func testSafetyTemperatureCacheRejectsExpiredAndFutureSamples() {
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        var cache = SafetyTemperatureCache()
        cache.record(31.5, at: recordedAt)

        XCTAssertEqual(cache.recentValue(at: recordedAt.addingTimeInterval(15), maxAge: 15), 31.5)
        XCTAssertNil(cache.recentValue(at: recordedAt.addingTimeInterval(15.001), maxAge: 15))
        XCTAssertNil(cache.recentValue(at: recordedAt.addingTimeInterval(-1), maxAge: 15))
        XCTAssertNil(cache.recentValue(at: recordedAt, maxAge: .infinity))

        cache.clear()
        XCTAssertNil(cache.recentValue(at: recordedAt, maxAge: 15))
    }
}
