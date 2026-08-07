import XCTest
import AppKit
@testable import BatteryGuard


@MainActor
final class AppActivationControllerTests: XCTestCase {
    func testShowingAWindowAppliesRegularPolicyBeforeActivation() {
        var calls: [String] = []
        let controller = AppActivationController(
            setPolicy: { policy in
                calls.append("policy:\(policy.rawValue)")
                return true
            },
            activate: { calls.append("activate") },
            hasVisibleAppWindow: { false },
            diagnostics: .disabled
        )

        XCTAssertTrue(controller.showAppWindow())
        XCTAssertEqual(calls, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate"])
    }

    func testRejectedRegularPolicyDoesNotPretendToActivate() {
        var didActivate = false
        let controller = AppActivationController(
            setPolicy: { _ in false },
            activate: { didActivate = true },
            hasVisibleAppWindow: { false },
            diagnostics: .disabled
        )

        XCTAssertFalse(controller.showAppWindow())
        XCTAssertFalse(didActivate)
    }

    func testAccessoryPolicyIsRestoredOnlyAfterTheLastWindowCloses() {
        var hasVisibleWindow = true
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = AppActivationController(
            setPolicy: { policies.append($0); return true },
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
}
