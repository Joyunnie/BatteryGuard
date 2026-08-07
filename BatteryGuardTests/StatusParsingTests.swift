import XCTest
@testable import BatteryGuard


final class StatusParsingTests: XCTestCase {
    func testParsesCompleteStatusCSV() {
        XCTAssertEqual(
            SMCKit.parseControlStatus(csv: "80,00:10,disabled,not discharging,80"),
            BatteryControlStatus(charging: .disabled, isDischarging: false, maintainLevel: 80)
        )
        XCTAssertEqual(
            SMCKit.parseControlStatus(csv: "79,00:10,enabled,discharging,65"),
            BatteryControlStatus(charging: .enabled, isDischarging: true, maintainLevel: 65)
        )
    }

    func testRejectsMalformedStatusInsteadOfGuessing() {
        XCTAssertNil(SMCKit.parseControlStatus(csv: ""))
        XCTAssertNil(SMCKit.parseControlStatus(csv: "80,00:10,disabled"))
        XCTAssertEqual(SMCKit.parseChargingStatus(csv: "bad"), .unknown)
    }

    func testMaintainWorkerClassificationRejectsDuplicatesAndStalePIDFiles() {
        let path = "/usr/local/co.palokaj.battery/battery"
        let processTable = """
         101 100 /bin/bash \(path) maintain_synchronous 80
         202 200 /bin/bash \(path) maintain_synchronous 80
         303 300 /bin/bash /tmp/unrelated maintain_synchronous 80
        """

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 202,
                processTable: processTable,
                batteryPath: path
            ),
            .duplicate(pids: [101, 202])
        )
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 404,
                processTable: "101 100 /bin/bash \(path) maintain_synchronous 80",
                batteryPath: path
            ),
            .stale(pid: 404)
        )
    }

    func testMaintainWorkerClassificationRequiresExactCommandTokens() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        let unrelated = "123 123 /tmp/helper --note=\(batteryPath) --mode=maintain_synchronous"

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 123,
                processTable: unrelated,
                batteryPath: batteryPath
            ),
            .stale(pid: 123)
        )

        let standaloneTokens = "123 123 /bin/echo \(batteryPath) maintain_synchronous 80"
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 123,
                processTable: standaloneTokens,
                batteryPath: batteryPath
            ),
            .stale(pid: 123)
        )
    }

    func testMaintainWorkerClassificationBindsTheWorkerTarget() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 101,
                processTable: "101 100 /bin/bash \(batteryPath) maintain_synchronous 60",
                batteryPath: batteryPath
            ),
            .running(pid: 101, target: 60)
        )
    }
}
