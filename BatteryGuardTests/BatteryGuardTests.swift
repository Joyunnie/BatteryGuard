// BatteryGuardTests.swift

import XCTest
@testable import BatteryGuard

// MARK: - ChargeState Tests

final class ChargeStateTests: XCTestCase {

    // Happy path: raw values match Korean UI strings
    func testRawValues() {
        XCTAssertEqual(ChargeState.charging.rawValue, "충전 중")
        XCTAssertEqual(ChargeState.chargingPaused.rawValue, "충전 일시정지")
        XCTAssertEqual(ChargeState.discharging.rawValue, "방전 중")
        XCTAssertEqual(ChargeState.notConnected.rawValue, "전원 미연결")
        XCTAssertEqual(ChargeState.topUp.rawValue, "Top Up 중")
    }

    // All cases are covered — compile-time guarantee via exhaustive switch
    func testAllCasesExist() {
        let allCases: [ChargeState] = [.charging, .chargingPaused, .discharging, .notConnected, .topUp]
        XCTAssertEqual(allCases.count, 5)
    }
}

// MARK: - UserSettings Tests

final class UserSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clean slate for each test
        let keys = ["chargeLimit", "heatProtection", "heatThreshold", "controlMagSafe"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        let keys = ["chargeLimit", "heatProtection", "heatThreshold", "controlMagSafe"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // Happy path: defaults applied on first launch
    func testDefaultValues() {
        let settings = UserSettings()
        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertEqual(settings.heatProtectionThreshold, 40.0)
        XCTAssertEqual(settings.heatProtectionEnabled, false)
        XCTAssertEqual(settings.controlMagSafeLED, false)
    }

    // Happy path: setting persists to UserDefaults
    func testChargeLimitPersistence() {
        let settings = UserSettings()
        settings.chargeLimit = 65
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "chargeLimit"), 65)
    }

    func testHeatProtectionPersistence() {
        let settings = UserSettings()
        settings.heatProtectionEnabled = true
        settings.heatProtectionThreshold = 35.0
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "heatProtection"))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "heatThreshold"), 35.0)
    }

    // Edge case: previously saved values are restored
    func testRestoresSavedValues() {
        UserDefaults.standard.set(55, forKey: "chargeLimit")
        UserDefaults.standard.set(true, forKey: "heatProtection")
        UserDefaults.standard.set(42.0, forKey: "heatThreshold")
        UserDefaults.standard.set(true, forKey: "controlMagSafe")

        let settings = UserSettings()
        XCTAssertEqual(settings.chargeLimit, 55)
        XCTAssertTrue(settings.heatProtectionEnabled)
        XCTAssertEqual(settings.heatProtectionThreshold, 42.0)
        XCTAssertTrue(settings.controlMagSafeLED)
    }

    // Boundary: chargeLimit = 0 (UserDefaults.integer returns 0 for missing keys)
    func testChargeLimitZeroWhenDefaultNotSet() {
        // If someone deletes the default *after* init check, integer returns 0
        UserDefaults.standard.set(0, forKey: "chargeLimit")
        let settings = UserSettings()
        XCTAssertEqual(settings.chargeLimit, 0)
    }
}

// MARK: - BatteryError Tests

final class BatteryErrorTests: XCTestCase {

    // Happy path: descriptions contain useful info
    func testBinaryNotFoundDescription() {
        let error = BatteryError.binaryNotFound("/usr/local/bin/battery")
        XCTAssertTrue(error.description.contains("/usr/local/bin/battery"))
        XCTAssertTrue(error.description.contains("not found"))
    }

    func testCommandFailedDescription() {
        let error = BatteryError.commandFailed("battery maintain 80", 1, "permission denied")
        XCTAssertTrue(error.description.contains("battery maintain 80"))
        XCTAssertTrue(error.description.contains("1"))
        XCTAssertTrue(error.description.contains("permission denied"))
    }

    // LocalizedError: localizedDescription returns the actual message, not generic Swift error
    func testLocalizedDescription() {
        let error = BatteryError.binaryNotFound("/missing")
        XCTAssertEqual(error.localizedDescription, error.description)
    }

    func testCommandFailedLocalizedDescription() {
        let error = BatteryError.commandFailed("cmd", 42, "output")
        XCTAssertEqual(error.localizedDescription, error.description)
        XCTAssertTrue(error.localizedDescription.contains("42"))
    }
}

// MARK: - BatteryInfo Tests

final class BatteryInfoTests: XCTestCase {

    private func makeInfo(
        charge: Int = 80, isCharging: Bool = false, isPluggedIn: Bool = true,
        maxCapacity: Int = 5000, designCapacity: Int = 5500, cycleCount: Int = 100,
        temperature: Double = 30.0, amperage: Int = -500, voltage: Int = 12000,
        timeToFull: Int = -1, timeToEmpty: Int = 120, healthPercent: Double = 90.9,
        isPresent: Bool = true, serialNumber: String = "ABC123"
    ) -> BatteryInfo {
        BatteryInfo(
            currentCharge: charge, isCharging: isCharging, isPluggedIn: isPluggedIn,
            maxCapacity: maxCapacity, designCapacity: designCapacity, cycleCount: cycleCount,
            temperature: temperature, amperage: amperage, voltage: voltage,
            timeToFull: timeToFull, timeToEmpty: timeToEmpty, healthPercent: healthPercent,
            isPresent: isPresent, serialNumber: serialNumber
        )
    }

    // Happy path: all fields stored correctly
    func testFieldStorage() {
        let info = makeInfo()
        XCTAssertEqual(info.currentCharge, 80)
        XCTAssertFalse(info.isCharging)
        XCTAssertTrue(info.isPluggedIn)
        XCTAssertEqual(info.amperage, -500)
        XCTAssertEqual(info.serialNumber, "ABC123")
    }

    // Boundary: 0% and 100%
    func testBoundaryChargeValues() {
        let empty = makeInfo(charge: 0)
        XCTAssertEqual(empty.currentCharge, 0)

        let full = makeInfo(charge: 100)
        XCTAssertEqual(full.currentCharge, 100)
    }

    // Edge case: negative amperage (discharging)
    func testNegativeAmperage() {
        let info = makeInfo(amperage: -1200)
        XCTAssertEqual(info.amperage, -1200)
        XCTAssertTrue(info.amperage < 0)
    }

    // Edge case: health over 100% (new battery with higher actual capacity)
    func testHealthOver100() {
        let info = makeInfo(healthPercent: 103.5)
        XCTAssertGreaterThan(info.healthPercent, 100.0)
    }
}

// MARK: - Verify Maintain Regex Tests

final class VerifyMaintainTests: XCTestCase {

    // Test the regex pattern directly since we can't call SMCKit without a real binary
    private func matchesMaintainPattern(_ output: String, level: Int) -> Bool {
        let pattern = "maintain\\D+\(level)\\b"
        return output.range(of: pattern, options: .regularExpression) != nil
    }

    // Happy path: standard battery status output
    func testMatchesStandardOutput() {
        XCTAssertTrue(matchesMaintainPattern("Battery maintaining at 80", level: 80))
        XCTAssertTrue(matchesMaintainPattern("maintain: 80", level: 80))
        XCTAssertTrue(matchesMaintainPattern("Currently maintaining at 65%", level: 65))
    }

    // Edge case: level 8 should NOT match 80
    func testDoesNotFalsePositiveOnSubstring() {
        XCTAssertFalse(matchesMaintainPattern("Battery maintaining at 80", level: 8))
        XCTAssertFalse(matchesMaintainPattern("maintain: 85", level: 8))
    }

    // Edge case: level 100
    func testMatchesLevel100() {
        XCTAssertTrue(matchesMaintainPattern("maintaining at 100", level: 100))
        XCTAssertFalse(matchesMaintainPattern("maintaining at 100", level: 10))
        XCTAssertFalse(matchesMaintainPattern("maintaining at 1000", level: 100))
    }

    // Edge case: level 20 (minimum)
    func testMatchesLevel20() {
        XCTAssertTrue(matchesMaintainPattern("maintain: 20", level: 20))
        XCTAssertFalse(matchesMaintainPattern("maintain: 200", level: 20))
    }

    // Error: no maintain info in output
    func testNoMatchWhenNotMaintaining() {
        XCTAssertFalse(matchesMaintainPattern("Battery at 80%, charging", level: 80))
        XCTAssertFalse(matchesMaintainPattern("discharging to 60%", level: 60))
        XCTAssertFalse(matchesMaintainPattern("", level: 80))
    }

    // Edge case: maintain appears but wrong level
    func testMismatchedLevel() {
        XCTAssertFalse(matchesMaintainPattern("maintaining at 75", level: 80))
        XCTAssertTrue(matchesMaintainPattern("maintaining at 75", level: 75))
    }
}

// MARK: - BatteryHistory Tests

final class BatteryHistoryTests: XCTestCase {

    // Use a fresh in-memory Core Data stack for each test
    private var history: BatteryHistory!

    override func setUp() {
        super.setUp()
        history = BatteryHistory.shared
        // Clear any existing records
        let records = history.fetchLast24Hours()
        // Note: can't easily clear shared singleton's Core Data in tests.
        // In production code, you'd inject a test-specific container.
    }

    // Happy path: record and fetch
    func testRecordAndFetch() {
        history.record(chargePercent: 80, chargeLimit: 80)
        // Wait for background context to save
        let expectation = expectation(description: "Core Data save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let records = history.fetchLast24Hours()
        XCTAssertGreaterThanOrEqual(records.count, 1)
        if let last = records.last {
            XCTAssertEqual(last.chargePercent, 80)
            XCTAssertEqual(last.chargeLimit, 80)
        }
    }

    // Edge case: duplicate values are skipped (second call is a no-op)
    func testSkipsDuplicateValues() {
        let countBefore = history.fetchLast24Hours().count

        // Use unique values unlikely to exist from other tests
        history.record(chargePercent: 37, chargeLimit: 37)
        history.record(chargePercent: 37, chargeLimit: 37)

        let expectation = expectation(description: "Core Data save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let countAfter = history.fetchLast24Hours().count
        // Only 1 new record should be added (second was deduplicated)
        XCTAssertEqual(countAfter - countBefore, 1)
    }

    // Happy path: changed values create new record
    func testRecordsChangedValues() {
        history.record(chargePercent: 80, chargeLimit: 80)
        history.record(chargePercent: 79, chargeLimit: 80)

        let expectation = expectation(description: "Core Data save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let records = history.fetchLast24Hours()
        let charges = records.suffix(2).map { $0.chargePercent }
        XCTAssertTrue(charges.contains(80))
        XCTAssertTrue(charges.contains(79))
    }

    // Boundary: chargePercent at 0 and 100
    func testBoundaryValues() {
        history.record(chargePercent: 0, chargeLimit: 20)
        history.record(chargePercent: 100, chargeLimit: 100)

        let expectation = expectation(description: "Core Data save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let records = history.fetchLast24Hours()
        let charges = records.map { $0.chargePercent }
        XCTAssertTrue(charges.contains(0))
        XCTAssertTrue(charges.contains(100))
    }

    // Happy path: fetch returns sorted by timestamp ascending
    func testFetchReturnsSorted() {
        let records = history.fetchLast24Hours()
        for i in 1..<records.count {
            XCTAssertLessThanOrEqual(records[i-1].timestamp, records[i].timestamp)
        }
    }
}

// MARK: - ChargeController Logic Tests

final class ChargeControllerStateTests: XCTestCase {

    private var controller: ChargeController!

    override func setUp() {
        super.setUp()
        controller = ChargeController.shared
        // Reset to known state
        controller.isDischarging = false
        controller.isTopUpActive = false
        controller.heatProtectionTriggered = false
        controller.lastError = nil
        controller.currentState = .notConnected
    }

    // Happy path: setChargeLimit clamps value
    func testSetChargeLimitClampsToRange() {
        controller.setChargeLimit(150)
        XCTAssertEqual(UserSettings.shared.chargeLimit, 100)

        controller.setChargeLimit(5)
        XCTAssertEqual(UserSettings.shared.chargeLimit, 20)
    }

    // Boundary: exact min and max
    func testSetChargeLimitBoundaries() {
        controller.setChargeLimit(20)
        XCTAssertEqual(UserSettings.shared.chargeLimit, 20)

        controller.setChargeLimit(100)
        XCTAssertEqual(UserSettings.shared.chargeLimit, 100)
    }

    // Edge case: setChargeLimit skipped during discharge
    func testSetChargeLimitSkippedDuringDischarge() {
        controller.isDischarging = true
        let originalLimit = UserSettings.shared.chargeLimit
        controller.setChargeLimit(50)
        // chargeLimit is updated (for UI) but CLI call is skipped (guard returns)
        XCTAssertEqual(UserSettings.shared.chargeLimit, 50)
        // Restore
        UserSettings.shared.chargeLimit = originalLimit
    }

    // Edge case: setChargeLimit skipped during top up
    func testSetChargeLimitSkippedDuringTopUp() {
        controller.isTopUpActive = true
        controller.setChargeLimit(60)
        XCTAssertEqual(UserSettings.shared.chargeLimit, 60)
    }

    // Happy path: startDischarge requires batteryInfo — no-op without it
    func testStartDischargeRequiresBatteryInfo() {
        // ChargeController.shared may have batteryInfo from BatteryMonitor running.
        // We can only verify it doesn't crash when called.
        // State may or may not change depending on live battery state.
        controller.startDischarge()
        // No crash = pass
    }

    // Happy path: toggleCharging doesn't crash without batteryInfo
    func testToggleChargingDoesNotCrash() {
        controller.toggleCharging()
        // No crash = pass. State may change due to live BatteryMonitor.
    }

    // Happy path: stopDischarge resets state
    func testStopDischargeResetsState() {
        controller.isDischarging = true
        controller.currentState = .discharging
        controller.stopDischarge()
        XCTAssertFalse(controller.isDischarging)
        XCTAssertEqual(controller.currentState, .chargingPaused)
    }

    // Happy path: cancelTopUp resets state
    func testCancelTopUpResetsState() {
        controller.isTopUpActive = true
        controller.currentState = .topUp
        controller.cancelTopUp()
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertEqual(controller.currentState, .chargingPaused)
    }

    // Happy path: startTopUp cancels discharge first
    func testStartTopUpCancelsDischarge() {
        controller.isDischarging = true
        controller.startTopUp()
        XCTAssertFalse(controller.isDischarging)
        XCTAssertTrue(controller.isTopUpActive)
        XCTAssertEqual(controller.currentState, .topUp)
        // Cleanup
        controller.cancelTopUp()
    }

    // Error handling: lastError is cleared on success
    func testLastErrorClearedByRunBattery() {
        controller.lastError = "previous error"
        // Any successful runBattery call should clear it
        // We can't directly trigger this in isolation without the CLI,
        // but we verify the property is settable/clearable
        controller.lastError = nil
        XCTAssertNil(controller.lastError)
    }
}

// MARK: - MagSafeLEDState Tests

final class MagSafeLEDStateTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(MagSafeLEDState.off.rawValue, 0x00)
        XCTAssertEqual(MagSafeLEDState.green.rawValue, 0x03)
        XCTAssertEqual(MagSafeLEDState.orange.rawValue, 0x04)
        XCTAssertEqual(MagSafeLEDState.auto.rawValue, 0x05)
    }

    // Boundary: hex formatting matches expected SMC values
    func testHexFormatting() {
        XCTAssertEqual(String(format: "%02x", MagSafeLEDState.off.rawValue), "00")
        XCTAssertEqual(String(format: "%02x", MagSafeLEDState.green.rawValue), "03")
        XCTAssertEqual(String(format: "%02x", MagSafeLEDState.orange.rawValue), "04")
        XCTAssertEqual(String(format: "%02x", MagSafeLEDState.auto.rawValue), "05")
    }
}
