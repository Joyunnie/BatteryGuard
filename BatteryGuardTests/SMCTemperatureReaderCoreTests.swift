import XCTest

final class SMCTemperatureReaderCoreTests: XCTestCase {
    func testValidSMCResponseReturnsDecodedFloat() {
        var value: Float = 0

        XCTAssertEqual(BGTestReadTemperatureScenario(0, &value), 0)
        XCTAssertEqual(value, 42.25)
    }

    func testSMCReaderRejectsEveryInvalidResponseContract() {
        for scenario in 1...9 {
            var value: Float = 0

            XCTAssertNotEqual(
                BGTestReadTemperatureScenario(Int32(scenario), &value),
                0,
                "Scenario \(scenario) unexpectedly succeeded"
            )
        }
    }
}
