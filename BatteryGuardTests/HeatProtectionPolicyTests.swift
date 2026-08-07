import XCTest
import Foundation
@testable import BatteryGuard

final class HeatProtectionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func evaluate(
        temperature: Double? = 30,
        threshold: Double = 40,
        measurementContext: HeatMeasurementContext = .batteryInfoAvailable,
        mode: ChargeMode = .maintaining(limit: 80),
        effectiveLimit: Int = 80,
        ownership: BatteryControlOwnership = .batteryGuard(lastLimit: 80),
        retryAfter: Date? = nil
    ) -> HeatProtectionEvaluation {
        HeatProtectionPolicy.evaluate(
            HeatProtectionInput(
                temperature: temperature,
                threshold: threshold,
                measurementContext: measurementContext,
                mode: mode,
                effectiveLimit: effectiveLimit,
                ownership: ownership,
                retryAfter: retryAfter,
                now: now
            )
        )
    }

    func testUnavailableOrInvalidTemperatureFailsClosed() {
        XCTAssertEqual(
            evaluate(temperature: nil).action,
            .enter(previous: .maintaining(limit: 80))
        )
        XCTAssertEqual(
            evaluate(temperature: .nan).action,
            .enter(previous: .maintaining(limit: 80))
        )
        XCTAssertNil(evaluate(temperature: 200).temperature)
    }

    func testOnlyBatteryGuardOwnershipCanCreateHardwareActions() {
        let hotMode = ChargeMode.maintaining(limit: 80)
        let blockedMode = ChargeMode.heatBlocked(previous: .maintaining(limit: 80))

        XCTAssertEqual(evaluate(temperature: 45, mode: hotMode, ownership: .system(lastLimit: 80)).action, .none)
        XCTAssertEqual(evaluate(temperature: 30, mode: blockedMode, ownership: .releasing(lastLimit: 80)).action, .none)
    }

    func testHotTemperatureEntersUsingTheCurrentRestorableMode() {
        XCTAssertEqual(
            evaluate(
                temperature: 41,
                mode: .discharging(target: 60, returnLimit: 75)
            ).action,
            .enter(previous: .discharging(target: 60, returnLimit: 75))
        )
    }

    func testHotSampleReblocksAnInFlightRestoreUsingItsRecordedMode() {
        let previous = RestorableChargeMode.toppingUp(returnLimit: 70)

        XCTAssertEqual(
            evaluate(
                temperature: 41,
                mode: .transitioning(.restoringHeat(previous: previous)),
                retryAfter: now.addingTimeInterval(60)
            ).action,
            .enter(previous: previous)
        )
    }

    func testRestoreRequiresTwoDegreeHysteresis() {
        let blocked = ChargeMode.heatBlocked(previous: .maintaining(limit: 75))

        XCTAssertEqual(evaluate(temperature: 38.1, mode: blocked).action, .none)
        XCTAssertEqual(
            evaluate(temperature: 38, mode: blocked).action,
            .restore(previous: .maintaining(limit: 75))
        )
    }

    func testFailedStateRestoreRequiresBatteryInfoAndExpiredCooldown() {
        let failed = ChargeMode.failed(
            previous: .maintaining(limit: 75),
            message: "injected",
            disposition: .heatProtection
        )

        XCTAssertEqual(
            evaluate(
                temperature: 30,
                measurementContext: .batteryInfoUnavailable,
                mode: failed
            ).action,
            .none
        )
        XCTAssertEqual(
            evaluate(
                temperature: 30,
                mode: failed,
                retryAfter: now.addingTimeInterval(1)
            ).action,
            .none
        )
        XCTAssertEqual(
            evaluate(
                temperature: 30,
                mode: failed,
                retryAfter: now
            ).action,
            .restore(previous: .maintaining(limit: 75))
        )
    }

    func testManualFailureIsNeverReinterpretedAsHeatRestore() {
        let failed = ChargeMode.failed(
            previous: .maintaining(limit: 75),
            message: "hardware state unknown",
            disposition: .manualIntervention
        )

        XCTAssertEqual(evaluate(temperature: 30, mode: failed).action, .none)
        XCTAssertEqual(evaluate(temperature: 45, mode: failed).action, .none)
        XCTAssertEqual(evaluate(temperature: nil, mode: failed).action, .none)
    }

    func testExternalDriftNeverBecomesAnOwnedHeatTransition() {
        let drift = ChargeMode.externalDrift(
            expected: .maintaining(limit: 80),
            observed: .maintaining(limit: 60)
        )

        XCTAssertEqual(evaluate(temperature: 45, mode: drift).action, .none)
        XCTAssertEqual(evaluate(temperature: nil, mode: drift).action, .none)
    }

    func testRecoverableFailureDoesNotBecomeAnOwnedHeatTransition() {
        let failed = ChargeMode.failed(
            previous: .maintaining(limit: 80),
            message: "command failed after an uncertain mutation",
            disposition: .recoverPrevious
        )

        XCTAssertEqual(evaluate(temperature: 45, mode: failed).action, .none)
    }

    func testEntryCooldownAndExistingSafetyTransitionsPreventDuplicateEntry() {
        XCTAssertEqual(
            evaluate(temperature: 45, retryAfter: now.addingTimeInterval(1)).action,
            .none
        )
        XCTAssertEqual(
            evaluate(
                temperature: 45,
                mode: .transitioning(.enteringHeat(previous: .maintaining(limit: 80)))
            ).action,
            .none
        )
        XCTAssertEqual(
            evaluate(
                temperature: 45,
                mode: .externalDrift(
                    expected: .controlReleased(lastLimit: 80),
                    observed: .charging
                )
            ).action,
            .none
        )
    }
}
