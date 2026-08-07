import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
extension ChargeControllerSafetyTests {
    func testHeatProtectionPreemptsDischargeAndRequiresVerifiedDisable() async {
        let (controller, backend, monitor, settings) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 90
        )
        settings.chargeLimit = 80
        controller.processBatteryInfo(makeBatteryInfo(charge: 90, temperature: 30))

        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        XCTAssertTrue(monitor.isSleepPreventionActive)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 90, isCharging: false, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)

        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)
        XCTAssertFalse(controller.isDischarging)
        XCTAssertTrue(backend.operations.contains("request-cancellation"))
        XCTAssertTrue(backend.operations.contains("cancel-long"))
        XCTAssertTrue(backend.operations.contains("disable-charging"))
    }

    func testHeatProtectionRestoresRecordedModeOnlyAfterSafeTemperature() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        let hotInfo = makeBatteryInfo(temperature: 45)
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        backend.temperature = 37
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)

        let restored = await eventually { !controller.heatProtectionTriggered && !controller.isCommandPending }
        XCTAssertTrue(restored)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertEqual(controller.effectiveChargeLimit, 80)
    }

    func testRisingTemperatureInvalidatesAnInFlightRestore() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        controller.processBatteryInfo(makeBatteryInfo(temperature: 45))
        let initiallyProtected = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(initiallyProtected)

        backend.maintainDelay = 0.25
        backend.temperature = 37
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)
        let restoreStarted = await eventually { backend.operations.contains("maintain:80") }
        XCTAssertTrue(restoreStarted)

        backend.temperature = 45
        let hotAgain = makeBatteryInfo(temperature: 45)
        monitor.batteryInfo = hotAgain
        controller.processBatteryInfo(hotAgain)

        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)
        XCTAssertGreaterThanOrEqual(
            backend.operations.filter { $0 == "disable-charging" }.count,
            2
        )
    }

    func testPreemptedCompletionIsRecordedAsSuperseded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-superseded-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 80,
            diagnostics: log
        )
        backend.maintainDelay = 0.25
        let safeInfo = makeBatteryInfo(charge: 80, temperature: 30)
        monitor.batteryInfo = safeInfo
        controller.processBatteryInfo(safeInfo)

        controller.setChargeLimit(60)
        let maintainStarted = await eventually(timeout: 2) {
            backend.operations.contains("maintain:60")
        }
        XCTAssertTrue(maintainStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 80, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if events.contains(where: { $0.outcome == .superseded }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(events.contains {
            $0.operation == "apply Charge Limit" && $0.outcome == .superseded
        })
    }

    func testUnsafePostflightTemperatureReblocksInsteadOfPublishingRestoredMode() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        controller.processBatteryInfo(makeBatteryInfo(temperature: 45))
        let initiallyBlocked = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(initiallyBlocked)

        backend.enqueueTemperatures([37, nil])
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)

        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertFalse(controller.isDischarging)
        XCTAssertGreaterThanOrEqual(
            backend.operations.filter { $0 == "disable-charging" }.count,
            2
        )
    }

    func testMissingTemperatureBlocksAutomaticControlAndFailsClosed() async {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: nil,
            charge: 70
        )

        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: nil))
        controller.startTopUp()

        XCTAssertTrue(controller.lastError?.contains("degraded") == true)
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("top-up") }))
        let failedClosed = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(failedClosed)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
    }

    func testFailedHeatBlockKeepsConflictingControlsDisabled() async {
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 70
        )
        backend.failNext("disable-charging")

        controller.processBatteryInfo(makeBatteryInfo(charge: 70, temperature: 45))
        let attemptFinished = await eventually { !controller.isCommandPending }
        XCTAssertTrue(attemptFinished)
        XCTAssertFalse(controller.heatProtectionTriggered)
        XCTAssertTrue(controller.isHeatProtectionBlockingControls)

        controller.startTopUp()
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("top-up") }))
    }

    func testHeatPreemptionDoesNotLetCancelledTopUpRestoreMaintain() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70
        )
        backend.topUpDelay = 0.3
        let safeInfo = makeBatteryInfo(charge: 70, temperature: 30)
        monitor.batteryInfo = safeInfo
        controller.processBatteryInfo(safeInfo)
        controller.startTopUp()
        let topUpStarted = await eventually { backend.operations.contains("top-up:100") }
        XCTAssertTrue(topUpStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 70, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        let operations = backend.operations
        let disabledAt = try? XCTUnwrap(operations.lastIndex(of: "disable-charging"))
        if let disabledAt {
            XCTAssertFalse(operations[operations.index(after: disabledAt)...].contains("maintain:80"))
        }
    }

    func testUnsafeTopUpRestoreCancelsTheNewLongOperationBeforeReblocking() async {
        let (controller, backend, monitor, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 30,
            charge: 70
        )
        let safeInfo = makeBatteryInfo(charge: 70, temperature: 30)
        monitor.batteryInfo = safeInfo
        controller.processBatteryInfo(safeInfo)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)

        backend.temperature = 45
        let hotInfo = makeBatteryInfo(charge: 70, temperature: 45)
        monitor.batteryInfo = hotInfo
        controller.processBatteryInfo(hotInfo)
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        backend.enqueueTemperatures([37, nil])
        let coolInfo = makeBatteryInfo(charge: 70, temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)
        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)

        let longOperationIsActive = await backend.isLongRunningOperationActive()
        XCTAssertFalse(longOperationIsActive)
        XCTAssertGreaterThanOrEqual(
            backend.operations.filter { $0 == "cancel-long" }.count,
            2
        )
    }

    func testChangingThresholdDuringRestoreUsesTheLatestValue() async {
        let (controller, backend, monitor, settings) = makeSUT(
            heatProtectionEnabled: true,
            temperature: 45,
            charge: 80
        )
        controller.processBatteryInfo(makeBatteryInfo(temperature: 45))
        let protectionTriggered = await eventually { controller.heatProtectionTriggered }
        XCTAssertTrue(protectionTriggered)

        backend.maintainDelay = 0.25
        backend.temperature = 37
        let coolInfo = makeBatteryInfo(temperature: 37)
        monitor.batteryInfo = coolInfo
        controller.processBatteryInfo(coolInfo)
        let restoreStarted = await eventually { backend.operations.contains("maintain:80") }
        XCTAssertTrue(restoreStarted)
        settings.heatProtectionThreshold = 35

        let reblocked = await eventually {
            controller.heatProtectionTriggered && !controller.isCommandPending
        }
        XCTAssertTrue(reblocked)
    }

    func testSensorFailureIsLoggedAsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-sensor-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, backend, _, _) = makeSUT(
            heatProtectionEnabled: true,
            temperature: nil,
            diagnostics: log
        )
        backend.temperature = nil

        controller.processBatteryInfo(makeBatteryInfo(temperature: nil))
        let deadline = Date().addingTimeInterval(1)
        var recorded = false
        while Date() < deadline, !recorded {
            let events = await log.recentEvents()
            recorded = events.contains {
                $0.category == .sensor && $0.outcome == .failed && $0.message?.contains("온도") == true
            }
            if !recorded { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(recorded)
    }

}
