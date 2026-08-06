import XCTest
import ServiceManagement
import Combine
import Darwin
import AppKit
@testable import BatteryGuard

private let testDefaultsSuite = "com.jiwon.batteryguard.tests.isolated"

private func makeTestDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: testDefaultsSuite)!
    defaults.removePersistentDomain(forName: testDefaultsSuite)
    return defaults
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func makeExecutableFixture(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("batteryguard-fixture-\(UUID().uuidString)")
    try Data(contents.utf8).write(to: url, options: .atomic)
    guard Darwin.chmod(url.path, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return url
}

private final class FakeLaunchAtLoginService: LaunchAtLoginManaging {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    var registerError: Error?
    var unregisterError: Error?

    func register() throws {
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private final class FakeChargeBackend: ChargeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOperations: [String] = []
    private var failures: [String: Error] = [:]
    private var longRunning = false
    private var temperatureValue: Float? = 30
    private var maintainLevel = 80
    private var maintainWorkerRunning = true
    private var chargingStatus: BatteryChargingStatus = .disabled
    private var maintainDelayValue: TimeInterval = 0
    private var topUpDelayValue: TimeInterval = 0
    private var openDelayValue: TimeInterval = 0
    private var temperatureSequence: [Float?] = []
    private var ledDelayByRawValue: [UInt8: TimeInterval] = [:]
    private var controlStatusOverride: BatteryControlStatus?
    private var controlStatusDelayValue: TimeInterval = 0

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }

    private var longRunningActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return longRunning
    }

    var temperature: Float? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return temperatureValue
        }
        set {
            lock.lock()
            temperatureValue = newValue
            lock.unlock()
        }
    }

    var maintainDelay: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return maintainDelayValue
        }
        set {
            lock.lock()
            maintainDelayValue = newValue
            lock.unlock()
        }
    }

    var openDelay: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return openDelayValue
        }
        set {
            lock.lock()
            openDelayValue = newValue
            lock.unlock()
        }
    }

    var topUpDelay: TimeInterval {
        get { lock.withLock { topUpDelayValue } }
        set { lock.withLock { topUpDelayValue = newValue } }
    }

    func failNext(_ operation: String, error: Error = BatteryError.commandFailed("fake", 1, "injected failure")) {
        lock.lock()
        failures[operation] = error
        lock.unlock()
    }

    func enqueueTemperatures(_ values: [Float?]) {
        lock.withLock { temperatureSequence.append(contentsOf: values) }
    }

    func setLEDDelay(_ delay: TimeInterval, for state: MagSafeLEDState) {
        lock.withLock { ledDelayByRawValue[state.rawValue] = delay }
    }

    func setControlStatus(_ status: BatteryControlStatus?) {
        lock.withLock { controlStatusOverride = status }
    }

    func setControlStatusDelay(_ delay: TimeInterval) {
        lock.withLock { controlStatusDelayValue = delay }
    }

    func open() async throws {
        try record("open")
        let delay = lock.withLock { openDelayValue }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    func readControlStatus() async throws -> BatteryControlStatus {
        try record("read-status")
        let delay = lock.withLock { controlStatusDelayValue }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return lock.withLock {
            if let controlStatusOverride { return controlStatusOverride }
            return BatteryControlStatus(
                charging: chargingStatus,
                isDischarging: longRunning,
                maintainLevel: maintainLevel,
                maintainWorker: maintainWorkerRunning ? .running(pid: 4_242) : .stopped
            )
        }
    }

    func applyMaintain(level: Int) async throws {
        try record("maintain", detail: "\(level)")
        let state = lock.withLock {
            maintainLevel = level
            chargingStatus = .disabled
            maintainWorkerRunning = true
            return (maintainDelayValue, longRunning)
        }
        if state.0 > 0 {
            try await Task.sleep(nanoseconds: UInt64(state.0 * 1_000_000_000))
        }
        if state.1 {
            lock.withLock { maintainWorkerRunning = false }
            throw BatteryError.commandFailed("maintain", -1, "long-running operation is still active")
        }
    }

    func disableCharging() async throws {
        try record("disable-charging")
        let longOperationIsActive = lock.withLock {
            chargingStatus = .disabled
            maintainWorkerRunning = false
            return longRunning
        }
        if longOperationIsActive {
            throw BatteryError.commandFailed("disable charging", -1, "long-running operation is still active")
        }
    }

    func startDischarge(to level: Int) async throws {
        try record("discharge", detail: "\(level)")
        lock.withLock {
            maintainWorkerRunning = false
            chargingStatus = .disabled
            longRunning = true
        }
    }

    func startTopUp(to level: Int) async throws {
        try record("top-up", detail: "\(level)")
        let delay = lock.withLock { topUpDelayValue }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lock.withLock {
            maintainWorkerRunning = false
            chargingStatus = .enabled
            longRunning = true
        }
    }

    func isLongRunningOperationActive() async -> Bool { longRunningActive }

    func longRunningOperationResult() async -> BatteryCommandResult? { nil }

    func cancelLongRunningOperation() async throws {
        try record("cancel-long")
        setLongRunning(false)
    }

    func requestCancellation() async throws {
        try record("request-cancellation")
        setLongRunning(false)
    }

    func readBatteryTemperature() async throws -> Float {
        try record("read-temperature")
        let nextTemperature = lock.withLock {
            temperatureSequence.isEmpty ? temperatureValue : temperatureSequence.removeFirst()
        }
        guard let nextTemperature else {
            throw BatteryError.commandFailed("temperature", 1, "sensor unavailable")
        }
        return nextTemperature
    }

    func setMagSafeLED(_ state: MagSafeLEDState) async throws {
        let delay = lock.withLock { ledDelayByRawValue[state.rawValue] ?? 0 }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try record("set-led", detail: String(format: "%02x", state.rawValue))
    }

    func restoreMagSafeLED() async throws { try record("restore-led") }

    private func setLongRunning(_ value: Bool) {
        lock.lock()
        longRunning = value
        lock.unlock()
    }

    private func record(_ operation: String, detail: String? = nil) throws {
        lock.lock()
        recordedOperations.append(detail.map { "\(operation):\($0)" } ?? operation)
        let error = failures.removeValue(forKey: operation)
        lock.unlock()
        if let error { throw error }
    }
}

private func makeBatteryInfo(
    charge: Int = 80,
    isCharging: Bool = false,
    isPluggedIn: Bool = true,
    temperature: Double? = 30,
    amperage: Int? = -500,
    health: Double? = 90
) -> BatteryInfo {
    BatteryInfo(
        currentCharge: charge,
        isCharging: isCharging,
        isPluggedIn: isPluggedIn,
        maxCapacity: 5_000,
        designCapacity: 5_500,
        cycleCount: 100,
        temperature: temperature,
        amperage: amperage,
        voltage: 12_000,
        timeToFull: -1,
        timeToEmpty: 120,
        healthPercent: health,
        isPresent: true,
        serialNumber: "TEST"
    )
}

final class ChargeStateTests: XCTestCase {
    func testAllStatesHaveStableLabels() {
        XCTAssertEqual(ChargeState.unknown.rawValue, "상태 확인 필요")
        XCTAssertEqual(ChargeState.charging.rawValue, "충전 중")
        XCTAssertEqual(ChargeState.chargingPaused.rawValue, "충전 일시정지")
        XCTAssertEqual(ChargeState.discharging.rawValue, "방전 중")
        XCTAssertEqual(ChargeState.notConnected.rawValue, "전원 미연결")
        XCTAssertEqual(ChargeState.topUp.rawValue, "Top Up 중")
    }
}

@MainActor
final class UserSettingsTests: XCTestCase {
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
    }
}

final class ProcessLifecycleTests: XCTestCase {
    private let termIgnoringShell = ["-c", "trap '' TERM; while true; do :; done"]

    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    func testTimeoutEscalatesAndReturnsStructuredResultWithinBoundedTime() async throws {
        let backend = SMCKit()
        let startedAt = Date()

        let result = try await backend.runFixtureForTesting(
            executable: "/bin/sh",
            arguments: termIgnoringShell,
            timeout: 0.05
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testExternalCancellationReachesRunningProcess() async throws {
        let backend = SMCKit()
        let arguments = termIgnoringShell
        let operation = Task {
            try await backend.runFixtureForTesting(
                executable: "/bin/sh",
                arguments: arguments,
                timeout: 5
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        try await backend.requestCancellation()
        let result = try await operation.value

        XCTAssertEqual(result.termination, .cancelled)
    }

    func testTaskCancellationStopsChildAndThrowsCancellation() async throws {
        let runner = BatteryCommandRunner()
        let arguments = termIgnoringShell
        let operation = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: arguments,
                    label: "task cancellation fixture",
                    timeout: 5
                )
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected: cancellation propagated through the runner to the child.
        }
    }

    func testSpawnFailurePreservesCommandLabel() async {
        let runner = BatteryCommandRunner()
        do {
            _ = try await runner.run(
                .init(
                    executable: "/definitely/missing/batteryguard-fixture",
                    arguments: [],
                    label: "missing fixture",
                    timeout: 1
                )
            )
            XCTFail("Expected spawn failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing fixture"))
        }
    }

    func testCapturesStdoutStderrAndExitCode() async throws {
        let backend = SMCKit()
        let result = try await backend.runFixtureForTesting(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"],
            timeout: 1
        )

        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    func testRunnerSerializesQueuedCommands() async throws {
        let runner = BatteryCommandRunner()
        let eventFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-serialization-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: eventFile) }
        let quotedEventFile = shellQuote(eventFile.path)
        let first = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo first-start >> \(quotedEventFile); sleep 0.2; echo first-end >> \(quotedEventFile); printf first"
                    ],
                    label: "first",
                    timeout: 1
                )
            )
        }
        let firstStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("first-start")) == true
        }
        XCTAssertTrue(firstStarted)

        let second = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "echo second >> \(quotedEventFile); printf second"],
                label: "second",
                timeout: 1
            )
        )

        let firstResult = try await first.value
        XCTAssertEqual(firstResult.stdout, "first")
        XCTAssertEqual(second.stdout, "second")
        let events = try String(contentsOf: eventFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }

    func testLongRunningLaunchWaitsForActiveOneShotCommand() async throws {
        let runner = BatteryCommandRunner()
        let eventFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-long-serialization-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: eventFile) }
        let quotedEventFile = shellQuote(eventFile.path)

        let first = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "echo one-shot-start >> \(quotedEventFile); sleep 0.2; echo one-shot-end >> \(quotedEventFile)"
                    ],
                    label: "one-shot before long launch",
                    timeout: 1
                )
            )
        }
        let oneShotStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("one-shot-start")) == true
        }
        XCTAssertTrue(oneShotStarted)

        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo long-start >> \(quotedEventFile); trap '' TERM; while true; do :; done"
                ],
                label: "serialized long launch"
            )
        )
        _ = try await first.value
        let longStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("long-start")) == true
        }
        XCTAssertTrue(longStarted)
        _ = try await runner.cancelLongRunning()

        let events = try String(contentsOf: eventFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(events, ["one-shot-start", "one-shot-end", "long-start"])
    }

    func testCapturedOutputIsBounded() async throws {
        let runner = BatteryCommandRunner()
        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 100000"],
                label: "bounded output fixture",
                timeout: 1
            )
        )

        XCTAssertEqual(result.stdout.utf8.count, 64 * 1024)
        XCTAssertEqual(result.termination, .exited)
    }

    func testDiscardedStdoutStillCapturesBoundedStderr() async throws {
        let runner = BatteryCommandRunner()
        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/yes e | /usr/bin/head -c 100000 >&2"],
                label: "bounded stderr fixture",
                timeout: 1,
                outputPolicy: .discardStdoutCaptureStderr
            )
        )

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.utf8.count, 64 * 1024)
    }

    func testStderrCaptureDoesNotWaitForADetachedDescendantToCloseThePipe() async throws {
        let runner = BatteryCommandRunner()
        let parentPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-stderr-parent-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: parentPIDFile) }
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \(shellQuote(parentPIDFile.path)); printf parent-error >&2; sleep 30 & exit 7"
                ],
                label: "inherited stderr fixture",
                timeout: 1,
                outputPolicy: .discardStdoutCaptureStderr
            )
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let parentPID = try XCTUnwrap(Int32(
            String(contentsOf: parentPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        _ = Darwin.kill(-parentPID, SIGTERM)

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stderr, "parent-error")
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testPersistentDescendantPolicyReturnsWithoutKillingTheWorker() async throws {
        let runner = BatteryCommandRunner()
        let parentPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-persistent-parent-\(UUID().uuidString).pid")
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-persistent-child-\(UUID().uuidString).pid")
        defer {
            try? FileManager.default.removeItem(at: parentPIDFile)
            try? FileManager.default.removeItem(at: childPIDFile)
        }

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \(shellQuote(parentPIDFile.path)); sleep 30 & echo $! > \(shellQuote(childPIDFile.path)); printf launched"
                ],
                label: "persistent descendant fixture",
                timeout: 1,
                descendantPolicy: .allowPersistentProcessGroup
            )
        )
        let parentPID = try XCTUnwrap(Int32(
            String(contentsOf: parentPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { _ = Darwin.kill(-parentPID, SIGKILL) }

        XCTAssertEqual(result.stdout, "launched")
        XCTAssertEqual(Darwin.kill(childPID, 0), 0)
    }

    func testSecondLongRunningLaunchIsRejectedWithoutStoppingTheFirst() async throws {
        let runner = BatteryCommandRunner()
        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: termIgnoringShell,
                label: "first long fixture"
            )
        )

        do {
            _ = try await runner.launchLongRunning(
                .init(
                    executable: "/bin/sh",
                    arguments: ["-c", "exit 0"],
                    label: "second long fixture"
                )
            )
            XCTFail("Expected the second long-running launch to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("first long fixture"))
        }

        let firstIsStillActive = await runner.isLongRunningActive()
        XCTAssertTrue(firstIsStillActive)
        _ = try await runner.cancelLongRunning()
    }

    func testTimeoutLeavesNoFixtureProcessBehind() async throws {
        let runner = BatteryCommandRunner()
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-runner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > '\(pidFile.path)'; trap '' TERM; while true; do :; done"
                ],
                label: "timeout cleanup fixture",
                timeout: 0.05
            )
        )

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutKillsDescendantsInTheSpawnedProcessGroup() async throws {
        let runner = BatteryCommandRunner()
        let parentPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-parent-\(UUID().uuidString).pid")
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-child-\(UUID().uuidString).pid")
        defer {
            try? FileManager.default.removeItem(at: parentPIDFile)
            try? FileManager.default.removeItem(at: childPIDFile)
        }

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "echo $$ > \(shellQuote(parentPIDFile.path)); sleep 30 & echo $! > \(shellQuote(childPIDFile.path)); trap '' TERM; while true; do :; done"
                ],
                label: "process group cleanup fixture",
                timeout: 0.05
            )
        )

        let parentPID = try XCTUnwrap(Int32(
            String(contentsOf: parentPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        XCTAssertEqual(result.termination, .timedOut)
        let parentExited = await eventually { Darwin.kill(parentPID, 0) == -1 && errno == ESRCH }
        let childExited = await eventually { Darwin.kill(childPID, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(parentExited)
        XCTAssertTrue(childExited)
    }

    func testLongRunningEarlyExitPreservesFailureOutput() async throws {
        let runner = BatteryCommandRunner()
        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "printf long-failure >&2; exit 9"],
                label: "long fixture",
                timeout: 1
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let isActive = await runner.isLongRunningActive()
        let capturedResult = await runner.longRunningResult()
        XCTAssertFalse(isActive)
        let result = try XCTUnwrap(capturedResult)
        XCTAssertEqual(result.exitCode, 9)
        XCTAssertEqual(result.stderr, "long-failure")
        XCTAssertEqual(result.termination, .exited)
    }
}

final class SMCKitOperationSafetyTests: XCTestCase {
    private func eventually(
        timeout: TimeInterval = 2.5,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    func testFailedLongRunningVerificationCleansUpTheStartedProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-verification-\(UUID().uuidString).pid")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            case "$1" in
              charge)
                echo $$ > \(shellQuote(pidFile.path))
                trap '' TERM
                while true; do :; done
                ;;
              status_csv)
                echo verification-status-failed >&2
                exit 7
                ;;
            esac
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.startTopUp(to: 100)
            XCTFail("Expected status verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("verification-status-failed"))
        }

        let pid = try XCTUnwrap(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let processExited = await eventually { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
        let isStillActive = await backend.isLongRunningOperationActive()
        XCTAssertTrue(processExited)
        XCTAssertFalse(isStillActive)
    }

    func testControlCommandAndVerificationRemainAtomic() async throws {
        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-maintain-state-\(UUID().uuidString)")
        let eventFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-maintain-events-\(UUID().uuidString)")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            case "$1" in
              maintain)
                echo "$2" > \(shellQuote(stateFile.path))
                echo "maintain-$2" >> \(shellQuote(eventFile.path))
                sleep 0.15
                ;;
              status_csv)
                value=$(cat \(shellQuote(stateFile.path)))
                echo "status-$value" >> \(shellQuote(eventFile.path))
                echo "80,00:10,disabled,not discharging,$value"
                ;;
            esac
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: stateFile)
            try? FileManager.default.removeItem(at: eventFile)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242) },
            executableTrustPolicy: .testFixture
        )

        let first = Task { try await backend.applyMaintain(level: 60) }
        let firstMaintainStarted = await eventually {
            (try? String(contentsOf: eventFile, encoding: .utf8).contains("maintain-60")) == true
        }
        XCTAssertTrue(firstMaintainStarted)
        let second = Task { try await backend.applyMaintain(level: 80) }
        try await first.value
        try await second.value

        let events = try String(contentsOf: eventFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(events, ["maintain-60", "status-60", "maintain-80", "status-80"])
    }

    func testVerifiedOperationAndItsCommandsShareOneCorrelationID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-smc-correlation-\(UUID().uuidString)", isDirectory: true)
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: directory)
        }
        let runner = BatteryCommandRunner(diagnostics: log)
        let backend = SMCKit(
            runner: runner,
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242) },
            executableTrustPolicy: .testFixture,
            diagnostics: log
        )

        try await backend.applyMaintain(level: 80)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if events.contains(where: { $0.category == .control }) &&
                events.filter({ $0.category == .command }).count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(events.contains { $0.operation == "maintain 80" && $0.category == .control })
        XCTAssertTrue(events.contains { $0.operation.contains("status_csv") && $0.category == .command })
        XCTAssertEqual(Set(events.compactMap(\.operationID)).count, 1)
        XCTAssertTrue(events.allSatisfy { $0.operationID != nil })
    }

    func testMaintainVerificationRejectsADeadWorkerEvenWhenTrackerMatches() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.applyMaintain(level: 80)
            XCTFail("Expected dead worker verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("worker=stopped"))
        }
    }

    func testMaintainVerificationRejectsConcurrentDischarge() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,discharging,80"
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242) },
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.applyMaintain(level: 80)
            XCTFail("Expected concurrent discharge verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("discharging=true"))
        }
    }

    func testDisableChargingRequiresNoDischargeAndNoMaintainWorker() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,discharging,80"
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.disableCharging()
            XCTFail("Expected incomplete charging-off verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fully disabled"))
        }
    }

    func testProductionPreflightRejectsAnUnpinnedExecutableBeforeUse() async throws {
        let fixture = try makeExecutableFixture("#!/bin/bash\necho v1.3.4\n")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(batteryPath: fixture.path)

        do {
            try await backend.open()
            XCTFail("Expected production preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Battery CLI preflight failed"))
        }
    }

    func testMaintainFailurePreservesStderrWhenStdoutIsDiscarded() async throws {
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "maintain" ]]; then
              echo maintain-error-detail >&2
              exit 23
            fi
            echo "80,00:10,disabled,not discharging,80"
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let backend = SMCKit(
            batteryPath: fixture.path,
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.applyMaintain(level: 80)
            XCTFail("Expected maintain failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("maintain-error-detail"))
            XCTAssertTrue(error.localizedDescription.contains("23"))
        }
    }

    func testLEDSnapshotAndRestoreCannotRace() async throws {
        let writeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-led-writes-\(UUID().uuidString)")
        let batteryFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "version" ]]; then
              echo "v1.3.4"
            else
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        let smcFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$3" == "-r" ]]; then
              sleep 0.15
              echo "[ACLC] 0 (bytes 05)"
            elif [[ "$3" == "-w" ]]; then
              echo "$4" >> \(shellQuote(writeFile.path))
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcFixture)
            try? FileManager.default.removeItem(at: writeFile)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcFixture.path,
            usesSudoForSMCWrites: false,
            executableTrustPolicy: .testFixture
        )
        try await backend.open()

        let setTask = Task { try await backend.setMagSafeLED(.orange) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let restoreTask = Task { try await backend.restoreMagSafeLED() }
        try await setTask.value
        try await restoreTask.value

        let writes = try String(contentsOf: writeFile, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(writes, ["04", "05"])
    }
}

final class BatteryValueTests: XCTestCase {
    func testUnavailableMeasurementsRemainUnavailable() {
        let info = makeBatteryInfo(temperature: nil, amperage: nil, health: nil)
        XCTAssertNil(info.temperature)
        XCTAssertNil(info.amperage)
        XCTAssertNil(info.healthPercent)
    }

    func testBatteryErrorsPreserveActionableContext() {
        let error = BatteryError.commandFailed("battery maintain 80", 42, "permission denied")
        XCTAssertTrue(error.localizedDescription.contains("battery maintain 80"))
        XCTAssertTrue(error.localizedDescription.contains("42"))
        XCTAssertTrue(error.localizedDescription.contains("permission denied"))
    }

    func testAmperageNormalizationPreservesDirectionAndRejectsImplausibleValues() {
        XCTAssertEqual(BatteryMonitor.normalizedAmperage(NSNumber(value: 1_250)), 1_250)
        XCTAssertEqual(BatteryMonitor.normalizedAmperage(NSNumber(value: -900)), -900)
        XCTAssertEqual(
            BatteryMonitor.normalizedAmperage(NSNumber(value: UInt64.max - 999)),
            -1_000
        )
        XCTAssertNil(BatteryMonitor.normalizedAmperage(NSNumber(value: 100_000)))
        XCTAssertEqual(BatteryDisplay.amperage(700), "+700 mA (충전)")
        XCTAssertEqual(BatteryDisplay.amperage(-700), "-700 mA (방전)")
        XCTAssertEqual(BatteryDisplay.amperage(nil), "알 수 없음")
    }

    func testBatteryDictionaryRejectsMissingOrOutOfRangeCharge() {
        XCTAssertNil(BatteryMonitor.parseBatteryInfo([:]))
        XCTAssertNil(BatteryMonitor.parseBatteryInfo(["CurrentCapacity": -1]))
        XCTAssertNil(BatteryMonitor.parseBatteryInfo(["CurrentCapacity": 101]))
    }

    func testMissingMeasurementsStayOptionalInsteadOfBecomingZero() throws {
        let info = try XCTUnwrap(BatteryMonitor.parseBatteryInfo(["CurrentCapacity": 50]))

        XCTAssertNil(info.maxCapacity)
        XCTAssertNil(info.designCapacity)
        XCTAssertNil(info.cycleCount)
        XCTAssertNil(info.voltage)
        XCTAssertNil(info.serialNumber)
    }

    func testTemperatureValidationRejectsNonfiniteAndImplausibleValues() {
        XCTAssertNil(BatteryMonitor.validatedTemperature(.nan))
        XCTAssertNil(BatteryMonitor.validatedTemperature(-273.05))
        XCTAssertNil(BatteryMonitor.validatedTemperature(101))
        XCTAssertEqual(BatteryMonitor.validatedTemperature(37.5), 37.5)

        let rawOne = BatteryMonitor.parseBatteryInfo([
            "CurrentCapacity": 50,
            "Temperature": 1
        ])
        XCTAssertNil(rawOne?.temperature)
    }
}

final class DiagnosticLogTests: XCTestCase {
    func testDiagnosticLogPersistsOnlyItsNewestHundredEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: fileURL, capacity: 100)

        for index in 0..<105 {
            await log.record(
                DiagnosticEvent(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    category: .control,
                    operation: "operation-\(index)"
                )
            )
        }

        let events = await log.recentEvents()
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.operation, "operation-5")
        XCTAssertEqual(events.last?.operation, "operation-104")

        let reloaded = DiagnosticLog(fileURL: fileURL, capacity: 100)
        let reloadedEvents = await reloaded.recentEvents()
        XCTAssertEqual(reloadedEvents, events)
    }

    func testCommandRunnerRecordsStructuredFailureDetails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-command-log-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(fileURL: fileURL, capacity: 10)
        let runner = BatteryCommandRunner(diagnostics: log)

        let result = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "echo diagnostic-failure >&2; exit 7"],
                label: "diagnostic fixture"
            )
        )
        XCTAssertEqual(result.exitCode, 7)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if !events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.last?.operation, "diagnostic fixture")
        XCTAssertEqual(events.last?.exitCode, 7)
        XCTAssertEqual(events.last?.message, "diagnostic-failure")
    }

    func testLongRunningLaunchAndExitUseUniqueEventIDsWithOneCorrelationID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-correlation-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = BatteryCommandRunner(diagnostics: log)
        let operationID = UUID()

        _ = try await DiagnosticContext.$operationID.withValue(operationID) {
            try await runner.launchLongRunning(
                .init(
                    executable: "/bin/sh",
                    arguments: ["-c", "trap '' TERM; while true; do :; done"],
                    label: "correlated fixture",
                    timeout: 2
                )
            )
        }
        _ = try await runner.cancelLongRunning()

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents().filter { $0.operation == "correlated fixture" }
            if events.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(Set(events.compactMap(\.commandID)).count, 1)
        XCTAssertEqual(Set(events.compactMap(\.operationID)), Set([operationID]))
        XCTAssertEqual(events.map(\.outcome), [.launched, .cancelled])
    }

    func testPrepareForViewingThrowsWhenTheLogCannotBePersisted() async throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-diagnostic-block-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        let log = DiagnosticLog(
            fileURL: blockingFile.appendingPathComponent("Diagnostics.json"),
            capacity: 10
        )
        await log.record(DiagnosticEvent(category: .lifecycle, operation: "persist failure"))

        do {
            _ = try await log.prepareForViewing()
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLegacyDiagnosticSchemaIsMigratedWhenRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-legacy-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Diagnostics.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventID = UUID()
        let legacyJSON = """
        [{
          "id": "\(eventID.uuidString)",
          "timestamp": "2026-08-06T00:00:00Z",
          "category": "command",
          "operationID": "\(eventID.uuidString)",
          "operation": "legacy command",
          "exitCode": 7,
          "termination": "failedBeforeResult",
          "stderrSummary": "legacy failure"
        }]
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let events = await DiagnosticLog(fileURL: fileURL, capacity: 10).recentEvents()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, eventID)
        XCTAssertEqual(events.first?.commandID, eventID)
        XCTAssertEqual(events.first?.outcome, .failed)
        XCTAssertEqual(events.first?.message, "legacy failure")
    }
}

@MainActor
final class BatteryHistoryTests: XCTestCase {
    func testHistoryUsesInMemoryStoreAndDeduplicates() async {
        let history = BatteryHistory(inMemory: true)
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)
        history.record(chargePercent: 80, chargeLimit: 80)
        history.record(chargePercent: 80, chargeLimit: 80)

        let records = history.fetchLast24Hours()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.chargePercent, 80)
        XCTAssertEqual(records.first?.chargeLimit, 80)
    }

    func testHistoryAddsHeartbeatForAnUnchangedInterval() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let history = BatteryHistory(
            inMemory: true,
            heartbeatInterval: 900,
            now: { clock.now() }
        )
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)

        history.record(chargePercent: 80, chargeLimit: 80)
        clock.advance(by: 899)
        history.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertEqual(history.fetchLast24Hours().count, 1)

        clock.advance(by: 2)
        history.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertEqual(history.fetchLast24Hours().count, 2)
    }

    func testDownsamplingNeverExceedsTheConfiguredLimitAndKeepsEndpoints() {
        let records = (0..<1_003).map {
            BatteryHistory.ChartRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                chargePercent: $0 % 101,
                chargeLimit: 80
            )
        }

        let sampled = BatteryHistory.downsample(records, maxPoints: 200)

        XCTAssertEqual(sampled.count, 200)
        XCTAssertEqual(sampled.first, records.first)
        XCTAssertEqual(sampled.last, records.last)
        XCTAssertTrue(BatteryHistory.downsample(records, maxPoints: 0).isEmpty)
    }

    func testPersistentStoreLoadFailureIsExposed() async throws {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-history-block-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }

        let history = BatteryHistory(storeURL: blockingFile.appendingPathComponent("history.sqlite"))
        let readiness = await history.waitUntilReady()

        guard case .failed(let message) = readiness else {
            return XCTFail("Expected failed readiness, received \(readiness)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(history.fetchLast24Hours().isEmpty)
    }

    func testSaveAndFetchFailuresAreExposedAndLogged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-history-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 10)
        defer { try? FileManager.default.removeItem(at: directory) }

        let saveFailure = BatteryHistory(
            inMemory: true,
            diagnostics: log,
            storeOperations: BatteryHistoryStoreOperations(
                save: { _ in throw BatteryError.commandFailed("save", 1, "injected save failure") }
            )
        )
        let saveReadiness = await saveFailure.waitUntilReady()
        XCTAssertEqual(saveReadiness, .ready)
        saveFailure.record(chargePercent: 80, chargeLimit: 80)
        XCTAssertTrue(saveFailure.saveError?.contains("injected save failure") == true)

        let fetchFailure = BatteryHistory(
            inMemory: true,
            diagnostics: log,
            storeOperations: BatteryHistoryStoreOperations(
                fetch: { _, _ in throw BatteryError.commandFailed("fetch", 1, "injected fetch failure") }
            )
        )
        let fetchReadiness = await fetchFailure.waitUntilReady()
        XCTAssertEqual(fetchReadiness, .ready)
        XCTAssertTrue(fetchFailure.fetchLast24Hours().isEmpty)
        XCTAssertTrue(fetchFailure.fetchError?.contains("injected fetch failure") == true)

        let deadline = Date().addingTimeInterval(1)
        var events: [DiagnosticEvent] = []
        while Date() < deadline {
            events = await log.recentEvents()
            if events.filter({ $0.category == .history }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.filter { $0.category == .history }.count, 2)
    }

    func testSuccessfulFetchClearsOnlyTheFetchError() async {
        var shouldFailFetch = true
        let history = BatteryHistory(
            inMemory: true,
            storeOperations: BatteryHistoryStoreOperations(
                fetch: { context, request in
                    if shouldFailFetch {
                        throw BatteryError.commandFailed("fetch", 1, "temporary fetch failure")
                    }
                    return try context.fetch(request)
                }
            )
        )
        let readiness = await history.waitUntilReady()
        XCTAssertEqual(readiness, .ready)

        XCTAssertTrue(history.fetchLast24Hours().isEmpty)
        XCTAssertNotNil(history.fetchError)
        shouldFailFetch = false
        XCTAssertTrue(history.fetchLast24Hours().isEmpty)
        XCTAssertNil(history.fetchError)
    }
}

@MainActor
final class ChargeControllerSafetyTests: XCTestCase {
    private func makeSUT(
        heatProtectionEnabled: Bool = false,
        temperature: Double? = 30,
        charge: Int = 80,
        isCharging: Bool = false,
        history: BatteryHistory? = nil,
        diagnostics: DiagnosticLog = .disabled
    ) -> (ChargeController, FakeChargeBackend, BatteryMonitor, UserSettings) {
        let backend = FakeChargeBackend()
        backend.temperature = temperature.map(Float.init)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { nil },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = makeBatteryInfo(
            charge: charge,
            isCharging: isCharging,
            temperature: temperature
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = heatProtectionEnabled
        return (
            ChargeController(
                backend: backend,
                monitor: monitor,
                settings: settings,
                initialReadiness: .ready,
                history: history,
                diagnostics: diagnostics
            ),
            backend,
            monitor,
            settings
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testControlsStayDisabledUntilInitializationAndInitialMaintainFinish() async throws {
        let backend = FakeChargeBackend()
        backend.openDelay = 0.2
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        let initialization = Task { try await controller.initialize() }
        let openStarted = await eventually { backend.operations.contains("open") }
        XCTAssertTrue(openStarted)
        XCTAssertEqual(controller.readiness, .initializing)

        controller.setChargeLimit(60)
        XCTAssertFalse(backend.operations.contains("maintain:60"))
        try await initialization.value

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertFalse(backend.operations.contains("maintain:60"))
    }

    func testInitializationBecomesReadyOnlyAfterHighTemperatureIsBlocked() async throws {
        let backend = FakeChargeBackend()
        backend.temperature = 45
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70, temperature: 45) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = true
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        try await controller.initialize()

        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertTrue(controller.heatProtectionTriggered)
        XCTAssertTrue(backend.operations.contains("disable-charging"))
        XCTAssertFalse(backend.operations.contains("maintain:80"))
    }

    func testInitializationFailureLeavesControlsUnavailable() async {
        let backend = FakeChargeBackend()
        backend.failNext("open")
        let monitor = BatteryMonitor(
            batteryInfoProvider: { makeBatteryInfo(charge: 70) },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)

        do {
            try await controller.initialize()
            XCTFail("Expected initialization failure")
        } catch {
            guard case .failed = controller.readiness else {
                return XCTFail("Expected failed readiness, received \(controller.readiness)")
            }
        }

        controller.startTopUp()
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("top-up") }))
    }

    func testChargeLimitCommitsOnlyAfterVerifiedBackendSuccess() async {
        let (controller, backend, _, settings) = makeSUT()

        controller.setChargeLimit(60)
        XCTAssertEqual(controller.displayedChargeLimit, 60)
        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertEqual(controller.effectiveChargeLimit, 80)

        let completed = await eventually { !controller.isChargeLimitPending && !controller.isCommandPending }
        XCTAssertTrue(completed)
        XCTAssertEqual(settings.chargeLimit, 60)
        XCTAssertEqual(controller.effectiveChargeLimit, 60)
        XCTAssertTrue(backend.operations.contains("maintain:60"))
    }

    func testChargeLimitFailureRollsUIBackToVerifiedValue() async {
        let (controller, backend, _, settings) = makeSUT()
        backend.failNext("maintain")

        controller.setChargeLimit(55)
        let completed = await eventually { !controller.isChargeLimitPending && !controller.isCommandPending }

        XCTAssertTrue(completed)
        XCTAssertEqual(controller.displayedChargeLimit, 80)
        XCTAssertEqual(controller.effectiveChargeLimit, 80)
        XCTAssertEqual(settings.chargeLimit, 80)
        XCTAssertNotNil(controller.lastError)
    }

    func testLongRunningLaunchFailureNeverEntersTopUpState() async {
        let (controller, backend, _, _) = makeSUT(charge: 70)
        backend.failNext("top-up")

        controller.startTopUp()
        let completed = await eventually { !controller.isCommandPending }

        XCTAssertTrue(completed)
        XCTAssertFalse(controller.isTopUpActive)
        XCTAssertNotEqual(controller.currentState, .topUp)
        XCTAssertNotNil(controller.lastError)
    }

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

    func testHistoryRecordsVerifiedModeLimitInsteadOfStoredPreference() async throws {
        let history = BatteryHistory(inMemory: true)
        let historyReadiness = await history.waitUntilReady()
        XCTAssertEqual(historyReadiness, .ready)
        let (controller, _, _, settings) = makeSUT(history: history)
        settings.chargeLimit = 60

        controller.processBatteryInfo(makeBatteryInfo(charge: 75))
        let record = try XCTUnwrap(history.fetchLast24Hours().last)
        XCTAssertEqual(record.chargeLimit, 80)
    }

    func testExternalMaintainDriftIsDisplayedLoggedAndClearsWhenCorrected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-drift-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(fileURL: directory.appendingPathComponent("Diagnostics.json"), capacity: 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, backend, _, _) = makeSUT(diagnostics: log)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 7_777)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertTrue(controller.hasExternalControlDrift)
        XCTAssertEqual(controller.effectiveChargeLimit, 60)
        XCTAssertTrue(controller.externalDriftDescription?.contains("60%") == true)
        XCTAssertTrue(controller.lastError?.contains("외부 CLI 변경 감지") == true)

        let deadline = Date().addingTimeInterval(1)
        var driftWasLogged = false
        while Date() < deadline, !driftWasLogged {
            driftWasLogged = await log.recentEvents().contains { $0.outcome == .drifted }
            if !driftWasLogged { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(driftWasLogged)

        await controller.reconcileExternalState()
        try await Task.sleep(nanoseconds: 50_000_000)
        let repeatedEvents = await log.recentEvents()
        XCTAssertEqual(repeatedEvents.filter { $0.outcome == .drifted }.count, 1)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_888)
            )
        )
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(controller.hasExternalControlDrift)
        XCTAssertNil(controller.externalDriftDescription)
    }

    func testExternalDischargeAndStatusFailureNeverLookLikeConfirmedMaintain() async {
        let history = BatteryHistory(inMemory: true)
        let historyReadiness = await history.waitUntilReady()
        XCTAssertEqual(historyReadiness, .ready)
        let (controller, backend, _, _) = makeSUT(history: history)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: true,
                maintainLevel: 80,
                maintainWorker: .stopped
            )
        )

        await controller.reconcileExternalState()
        XCTAssertEqual(controller.currentState, .discharging)
        XCTAssertTrue(controller.hasExternalControlDrift)
        controller.processBatteryInfo(makeBatteryInfo(charge: 80))
        XCTAssertTrue(history.fetchLast24Hours().isEmpty)

        backend.setControlStatus(nil)
        backend.failNext("read-status")
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.currentState, .unknown)
        XCTAssertTrue(controller.externalDriftDescription?.contains("확인할 수 없음") == true)
    }

    func testAppActivationTriggersDriftReconciliation() async throws {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 80)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(backend: backend, monitor: monitor, settings: settings)
        try await controller.initialize()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 65,
                maintainWorker: .running(pid: 6_565)
            )
        )

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        try await controller.shutdown()
    }

    func testPeriodicReconciliationDetectsTerminalDrift() async throws {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 80)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            reconciliationInterval: 0.05
        )
        try await controller.initialize()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 70,
                maintainWorker: .running(pid: 7_070)
            )
        )

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        try await controller.shutdown()
    }

    func testStaleReconciliationCannotOverwriteWakeRecovery() async {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 80)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            initialReadiness: .ready
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060)
            )
        )
        backend.setControlStatusDelay(0.15)

        let reconciliation = Task { await controller.reconcileExternalState() }
        let statusReadStarted = await eventually {
            backend.operations.contains("read-status")
        }
        XCTAssertTrue(statusReadStarted)

        await controller.reconcileAfterWake()
        await reconciliation.value

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(controller.hasExternalControlDrift)
    }

    func testExternalActiveOperationRejectsShutdownWithoutDisablingController() async throws {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        await controller.reconcileExternalState()

        do {
            try await controller.shutdown()
            XCTFail("Expected externally owned discharge to reject shutdown")
        } catch {
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.hasExternalControlDrift)
            XCTAssertFalse(backend.operations.contains("request-cancellation"))
        }

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080)
            )
        )
        await controller.reconcileExternalState()
        try await controller.shutdown()
    }

    func testDisablingLEDControlRestoresCapturedStateThroughBackend() async {
        let (controller, backend, _, settings) = makeSUT(charge: 50, isCharging: true)
        settings.controlMagSafeLED = true
        controller.processBatteryInfo(makeBatteryInfo(charge: 50, isCharging: true))
        let LEDWasSet = await eventually { backend.operations.contains("set-led:04") }
        XCTAssertTrue(LEDWasSet)

        settings.controlMagSafeLED = false
        controller.processBatteryInfo(makeBatteryInfo(charge: 50, isCharging: true))
        let LEDWasRestored = await eventually { backend.operations.contains("restore-led") }
        XCTAssertTrue(LEDWasRestored)
    }

    func testDisablingLEDWhileDischargingRestoresInsteadOfLosingSnapshot() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.controlMagSafeLED = true
        settings.chargeLimit = 80

        controller.startDischarge()
        let started = await eventually { controller.isDischarging }
        XCTAssertTrue(started)
        let dischargeInfo = makeBatteryInfo(charge: 90)
        monitor.batteryInfo = dischargeInfo
        controller.processBatteryInfo(dischargeInfo)
        let blinkStarted = await eventually { backend.operations.contains("set-led:04") }
        XCTAssertTrue(blinkStarted)

        settings.controlMagSafeLED = false
        controller.processBatteryInfo(dischargeInfo)
        let restored = await eventually { backend.operations.contains("restore-led") }
        XCTAssertTrue(restored)
    }

    func testNormalShutdownDoesNotStopPersistentMaintain() async throws {
        let (controller, backend, _, _) = makeSUT()
        try await controller.shutdown()

        XCTAssertFalse(backend.operations.contains("stop-maintain"))
    }

    func testWakeReconciliationSupersedesAnInFlightMaintainCompletion() async {
        let backend = FakeChargeBackend()
        backend.maintainDelay = 0.25
        let info = makeBatteryInfo(charge: 80, temperature: 30)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings,
            initialReadiness: .ready
        )

        controller.setChargeLimit(60)
        let maintainStarted = await eventually { backend.operations.contains("maintain:60") }
        XCTAssertTrue(maintainStarted)
        await controller.reconcileAfterWake()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertEqual(controller.readiness, .ready)
        XCTAssertFalse(controller.isCommandPending)
        XCTAssertEqual(backend.operations.last(where: { $0.hasPrefix("maintain:") }), "maintain:80")
    }

    func testShutdownFailureDoesNotPretendCleanupSucceeded() async {
        let (controller, backend, _, _) = makeSUT(charge: 70)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)
        backend.failNext("maintain")

        do {
            try await controller.shutdown()
            XCTFail("Expected shutdown cleanup failure")
        } catch {
            XCTAssertTrue(controller.lastError?.contains("종료 안전 정리 실패") == true)
            XCTAssertEqual(controller.readiness, .shuttingDown)
        }
    }

    func testShutdownDuringTopUpCancelsAndRestoresVerifiedMaintain() async throws {
        let (controller, backend, _, _) = makeSUT(charge: 70)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)

        try await controller.shutdown()

        XCTAssertTrue(backend.operations.contains("request-cancellation"))
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("read-status"))
    }

    func testShutdownDuringDischargeCancelsAndRestoresVerifiedMaintain() async throws {
        let (controller, backend, _, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)

        try await controller.shutdown()

        XCTAssertTrue(backend.operations.contains("request-cancellation"))
        XCTAssertTrue(backend.operations.contains("maintain:80"))
        XCTAssertTrue(backend.operations.contains("read-status"))
    }
}

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
