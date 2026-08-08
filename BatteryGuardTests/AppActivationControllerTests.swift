import XCTest
import AppKit
@testable import BatteryGuard


@MainActor
final class AppActivationControllerTests: XCTestCase {
    func testShowingAWindowAppliesRegularPolicyBeforeActivation() {
        var calls: [String] = []
        var currentPolicy = NSApplication.ActivationPolicy.accessory
        let controller = AppActivationController(
            currentPolicy: { currentPolicy },
            setPolicy: { policy in
                calls.append("policy:\(policy.rawValue)")
                currentPolicy = policy
                return true
            },
            activate: { calls.append("activate") },
            hasVisibleAppWindow: { false },
            diagnostics: .disabled
        )

        XCTAssertTrue(controller.showAppWindow())
        XCTAssertEqual(calls, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate"])
    }

    func testRejectedRegularPolicyDoesNotPretendToActivate() async {
        let log = DiagnosticLog(fileURL: nil, capacity: 10)
        var didActivate = false
        let controller = AppActivationController(
            currentPolicy: { .accessory },
            setPolicy: { _ in false },
            activate: { didActivate = true },
            hasVisibleAppWindow: { false },
            diagnostics: log
        )

        XCTAssertFalse(controller.showAppWindow())
        XCTAssertFalse(didActivate)
        await log.flushPendingEvents()
        let events = await log.recentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, .failed)
        XCTAssertTrue(events.first?.message?.contains("current=1, accepted=false") == true)
    }

    func testAccessoryPolicyIsRestoredOnlyAfterTheLastWindowCloses() {
        var hasVisibleWindow = true
        var currentPolicy = NSApplication.ActivationPolicy.regular
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = AppActivationController(
            currentPolicy: { currentPolicy },
            setPolicy: {
                policies.append($0)
                currentPolicy = $0
                return true
            },
            activate: {},
            hasVisibleAppWindow: { hasVisibleWindow },
            diagnostics: .disabled
        )

        XCTAssertTrue(controller.restoreAccessoryPolicyIfNeeded())
        XCTAssertTrue(policies.isEmpty)
        hasVisibleWindow = false
        XCTAssertTrue(controller.restoreAccessoryPolicyIfNeeded())
        XCTAssertEqual(policies, [.accessory])
    }

    func testInitialAccessoryPolicyDoesNotRepeatAnAlreadyAppliedTransition() async {
        let log = DiagnosticLog(fileURL: nil, capacity: 10)
        var setPolicyCalls = 0
        let controller = AppActivationController(
            currentPolicy: { .accessory },
            setPolicy: { _ in
                setPolicyCalls += 1
                return false
            },
            activate: {},
            hasVisibleAppWindow: { false },
            diagnostics: log
        )

        XCTAssertTrue(controller.setInitialAccessoryPolicy())
        XCTAssertEqual(setPolicyCalls, 0)
        await log.flushPendingEvents()
        let events = await log.recentEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testAcceptedPolicyTransitionRequiresVerifiedPostcondition() async {
        let log = DiagnosticLog(fileURL: nil, capacity: 10)
        var didActivate = false
        let controller = AppActivationController(
            currentPolicy: { .accessory },
            setPolicy: { _ in true },
            activate: { didActivate = true },
            hasVisibleAppWindow: { false },
            diagnostics: log
        )

        XCTAssertFalse(controller.showAppWindow())
        XCTAssertFalse(didActivate)
        await log.flushPendingEvents()
        let events = await log.recentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outcome, .failed)
        XCTAssertTrue(events.first?.message?.contains("current=1, accepted=true") == true)
    }
}
