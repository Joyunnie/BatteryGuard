import XCTest
import Foundation
@testable import BatteryGuard


final class MagSafeLEDStateTests: XCTestCase {
    func testOnlyExplicitColorsHaveHardCodedValues() {
        XCTAssertEqual(MagSafeLEDState.green.rawValue, 0x03)
        XCTAssertEqual(MagSafeLEDState.orange.rawValue, 0x04)
    }

    func testNewerGenerationWinsWhenAnOlderWriteIsSlow() async throws {
        let backend = FakeChargeBackend()
        backend.setLEDDelay(0.2, for: .orange)
        let controller = MagSafeLEDController(backend: backend)

        await controller.apply(.solid(.orange), generation: 1) { _ in }
        try await Task.sleep(nanoseconds: 20_000_000)
        await controller.apply(.solid(.green), generation: 2) { _ in }
        try await Task.sleep(nanoseconds: 350_000_000)

        let writes = backend.operations.filter { $0.hasPrefix("set-led:") }
        XCTAssertEqual(writes, ["set-led:04", "set-led:03"])
        try await controller.shutdown(generation: 3)
    }
}
