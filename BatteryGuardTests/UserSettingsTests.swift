import XCTest
import ServiceManagement
import Combine
import Darwin
import AppKit
@testable import BatteryGuard


@MainActor
final class UserSettingsTests: XCTestCase {
    func testBatteryControlOwnershipDefaultsEnabledAndPersistsExplicitRelease() throws {
        let defaults = makeTestDefaults()
        let journalURL = makeOwnershipJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let settings = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )

        XCTAssertTrue(settings.batteryControlEnabled)
        try settings.completeBatteryControlRelease(lastLimit: 75)

        let reloaded = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )
        XCTAssertFalse(reloaded.batteryControlEnabled)
        XCTAssertEqual(reloaded.batteryControlOwnership, .system(lastLimit: 75))
    }

    func testPendingControlReleaseSurvivesRestartWithoutClaimingReleasedState() throws {
        let defaults = makeTestDefaults()
        let journalURL = makeOwnershipJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        let settings = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )

        try settings.beginBatteryControlRelease(lastLimit: 70)

        let reloaded = UserSettings(
            defaults: defaults,
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )
        XCTAssertFalse(reloaded.batteryControlEnabled)
        XCTAssertTrue(reloaded.batteryControlReleasePending)
        XCTAssertTrue(reloaded.expectsReleasedBatteryControl)
        XCTAssertEqual(reloaded.batteryControlOwnership, .releasing(lastLimit: 70))
    }

    func testDefaultsAndPersistenceUseIsolatedDefaults() {
        let defaults = makeTestDefaults()
        let settings = UserSettings(defaults: defaults, launchAtLoginService: FakeLaunchAtLoginService())

        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertEqual(settings.heatProtectionThreshold, 40)

        settings.chargeLimit = 65
        settings.heatProtectionThreshold = 35
        XCTAssertEqual(defaults.integer(forKey: "chargeLimit"), 65)
        XCTAssertEqual(defaults.double(forKey: "heatThreshold"), 35)
    }

    func testInvalidValuesAreClampedBeforePublicationAndPersistence() {
        let defaults = makeTestDefaults()
        defaults.set(0, forKey: "chargeLimit")
        defaults.set(Double.nan, forKey: "heatThreshold")
        let settings = UserSettings(defaults: defaults, launchAtLoginService: FakeLaunchAtLoginService())

        XCTAssertEqual(settings.chargeLimit, 20)
        XCTAssertEqual(settings.heatProtectionThreshold, 40)

        var publishedChargeLimits: [Int] = []
        let cancellable = settings.objectWillChange.sink {
            publishedChargeLimits.append(settings.chargeLimit)
        }
        settings.chargeLimit = 500

        XCTAssertEqual(settings.chargeLimit, 100)
        XCTAssertFalse(publishedChargeLimits.contains(500))
        XCTAssertEqual(defaults.integer(forKey: "chargeLimit"), 100)
        _ = cancellable
    }

    func testLaunchAtLoginUsesInjectedServiceWithoutChangingSystemState() {
        let service = FakeLaunchAtLoginService()
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.launchAtLogin = true
        XCTAssertEqual(service.status, .enabled)
        XCTAssertTrue(settings.launchAtLogin)

        settings.launchAtLogin = false
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testLaunchAtLoginRollsBackWhenInjectedServiceFails() {
        let service = FakeLaunchAtLoginService()
        service.registerError = BatteryError.commandFailed("register", 1, "denied")
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.launchAtLogin = true
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNotNil(settings.launchAtLoginError)
    }

    func testLaunchAtLoginPreservesRequiresApprovalState() {
        let service = FakeLaunchAtLoginService()
        service.statusAfterRegister = .requiresApproval
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.launchAtLogin = true

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginState, .requiresApproval)
    }

    func testLaunchAtLoginReportsAStatusMismatchAfterRegistrationReturns() {
        let service = FakeLaunchAtLoginService()
        service.statusAfterRegister = .notRegistered
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)

        settings.setLaunchAtLogin(true)

        XCTAssertEqual(settings.launchAtLoginState, .disabled)
        XCTAssertNotNil(settings.launchAtLoginError)
    }

    func testRefreshingLaunchAtLoginStatusClearsAStaleActionError() {
        let service = FakeLaunchAtLoginService()
        service.registerError = BatteryError.commandFailed("register", 1, "denied")
        let settings = UserSettings(defaults: makeTestDefaults(), launchAtLoginService: service)
        settings.setLaunchAtLogin(true)
        XCTAssertNotNil(settings.launchAtLoginError)

        service.registerError = nil
        service.status = .enabled
        settings.refreshLaunchAtLoginStatus()

        XCTAssertEqual(settings.launchAtLoginState, .enabled)
        XCTAssertNil(settings.launchAtLoginError)
    }
}

