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
        XCTAssertNil(SMCKit.parseControlStatus(csv: "bad"))
    }

    func testMaintainWorkerClassificationRejectsDuplicatesAndStalePIDFiles() {
        let path = "/usr/local/co.palokaj.battery/battery"
        let pgrepOutput = """
         101 /bin/bash \(path) maintain_synchronous 80
         202 /bin/bash \(path) maintain_synchronous 80
         303 /bin/bash /tmp/unrelated maintain_synchronous 80
        """

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 202,
                pgrepOutput: pgrepOutput,
                batteryPath: path
            ),
            .duplicate(pids: [101, 202])
        )
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 404,
                pgrepOutput: "101 /bin/bash \(path) maintain_synchronous 80",
                batteryPath: path
            ),
            .stale(pid: 404)
        )
    }

    func testMaintainWorkerClassificationRequiresExactCommandTokens() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        let unrelated = "123 /tmp/helper --note=\(batteryPath) --mode=maintain_synchronous"

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 123,
                pgrepOutput: unrelated,
                batteryPath: batteryPath
            ),
            .stale(pid: 123)
        )

        let standaloneTokens = "123 /bin/echo \(batteryPath) maintain_synchronous 80"
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 123,
                pgrepOutput: standaloneTokens,
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
                pgrepOutput: "101 /bin/bash \(batteryPath) maintain_synchronous 60",
                batteryPath: batteryPath
            ),
            .running(pid: 101, target: 60)
        )
    }

    func testPgrepLongOutputRequiresAnExactMaintainCommand() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        let output = """
        101 /bin/bash \(batteryPath) maintain_synchronous 80
        202 /bin/zsh /tmp/helper --note=\(batteryPath) maintain_synchronous 80
        303 /bin/bash \(batteryPath) maintain_synchronous 80 unexpected
        """

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 101,
                pgrepOutput: output,
                batteryPath: batteryPath
            ),
            .running(pid: 101, target: 80)
        )
    }

    func testPgrepCandidateLimitIgnoresUnrelatedCommandLinesContainingBatteryPath() throws {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        let unrelated = (1...80).map { pid in
            "\(pid + 1000) /bin/zsh -c profile --cli \(batteryPath) --trial \(pid)"
        }
        let exactWorker = "101 /bin/bash \(batteryPath) maintain_synchronous 80"

        let candidates = try SMCKit.boundedPgrepMaintainWorkerProcesses(
            pgrepOutput: (unrelated + [exactWorker]).joined(separator: "\n"),
            batteryPath: batteryPath
        )

        XCTAssertEqual(candidates.map(\.pid), [101])
        XCTAssertEqual(candidates.map(\.target), [80])
    }

    func testPgrepCandidateLimitRejectsTooManyExactWorkers() {
        let batteryPath = "/usr/local/co.palokaj.battery/battery"
        let exactWorkers = (1...33).map { index in
            "\(index + 100) /bin/bash \(batteryPath) maintain_synchronous 80"
        }.joined(separator: "\n")

        XCTAssertThrowsError(
            try SMCKit.boundedPgrepMaintainWorkerProcesses(
                pgrepOutput: exactWorkers,
                batteryPath: batteryPath
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Command failed (-1): inspect battery CLI processes — "
                    + "refusing unbounded process inspection: 33 exact candidates"
            )
        }
    }

    func testMaintainWorkerObservationRejectsIdentityChangesAcrossArgvInspection() {
        let path = "/usr/local/co.palokaj.battery/battery"
        let command = "/bin/bash \(path) maintain_synchronous 80"
        let original = SMCKit.ProcessIdentity(startSeconds: 10, startMicroseconds: 20)
        let reused = SMCKit.ProcessIdentity(startSeconds: 11, startMicroseconds: 0)

        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 101,
                pgrepOutput: "101 \(command)",
                processTable: "101 101 \(command)",
                batteryPath: path,
                identitiesBefore: [101: original],
                identitiesAfter: [101: reused]
            ),
            .stale(pid: 101)
        )
        XCTAssertEqual(
            SMCKit.classifyMaintainWorkers(
                pidFilePID: 101,
                pgrepOutput: "101 \(command)",
                processTable: "101 101 \(command)",
                batteryPath: path,
                identitiesBefore: [101: original],
                identitiesAfter: [101: original]
            ),
            .running(pid: 101, target: 80)
        )
    }
}
