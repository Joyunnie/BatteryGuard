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

private func makeOwnershipJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("batteryguard-ownership-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("ownership.json", isDirectory: false)
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
    private var releaseDelayValue: TimeInterval = 0
    private var restoreLEDDelayValue: TimeInterval = 0
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

    var releaseDelay: TimeInterval {
        get { lock.withLock { releaseDelayValue } }
        set { lock.withLock { releaseDelayValue = newValue } }
    }

    var restoreLEDDelay: TimeInterval {
        get { lock.withLock { restoreLEDDelayValue } }
        set { lock.withLock { restoreLEDDelayValue = newValue } }
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

    func setOwnedLongRunningOperation(_ isActive: Bool) {
        setLongRunning(isActive)
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
                maintainWorker: maintainWorkerRunning
                    ? .running(pid: 4_242, target: maintainLevel)
                    : .stopped
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

    func releaseBatteryGuardControl() async throws {
        try record("release-control")
        let delay = lock.withLock { releaseDelayValue }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lock.withLock {
            longRunning = false
            maintainWorkerRunning = false
            chargingStatus = .enabled
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

    func restoreMagSafeLED() async throws {
        let delay = lock.withLock { restoreLEDDelayValue }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try record("restore-led")
    }

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

final class ChargeReconciliationPolicyTests: XCTestCase {
    private let releasedStatus = BatteryControlStatus(
        charging: .disabled,
        isDischarging: false,
        maintainLevel: 80,
        maintainWorker: .stopped
    )

    func testPendingReleaseCannotBeCompletedByReadOnlyStatus() {
        let snapshot = ChargeReconciliationSnapshot(
            status: releasedStatus,
            ownsLongRunningOperation: false
        )

        XCTAssertFalse(
            ChargeReconciliationPolicy.status(
                snapshot,
                matches: .controlReleasing(lastLimit: 80)
            )
        )
    }

    func testReleasedControlRequiresNoOwnedLongOperation() {
        XCTAssertTrue(
            ChargeReconciliationPolicy.status(
                ChargeReconciliationSnapshot(
                    status: releasedStatus,
                    ownsLongRunningOperation: false
                ),
                matches: .controlReleased(lastLimit: 80)
            )
        )
        XCTAssertFalse(
            ChargeReconciliationPolicy.status(
                ChargeReconciliationSnapshot(
                    status: releasedStatus,
                    ownsLongRunningOperation: true
                ),
                matches: .controlReleased(lastLimit: 80)
            )
        )
    }

    func testObservedMaintainRequiresMatchingLiveWorker() {
        let verified = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: 75,
            maintainWorker: .running(pid: 7_575, target: 75)
        )
        let deadWorker = BatteryControlStatus(
            charging: .disabled,
            isDischarging: false,
            maintainLevel: 75,
            maintainWorker: .stopped
        )

        XCTAssertEqual(
            ChargeReconciliationPolicy.observedMode(from: verified),
            .maintaining(limit: 75)
        )
        XCTAssertEqual(
            ChargeReconciliationPolicy.observedMode(from: deadWorker),
            .chargingDisabled
        )
    }

    func testPolicyMapsRestorableModesWithoutControllerState() {
        let mode = RestorableChargeMode.discharging(target: 65, returnLimit: 80)
        let expectation = ChargeReconciliationPolicy.expectation(from: mode)

        XCTAssertEqual(expectation, .discharging(target: 65, returnLimit: 80))
        XCTAssertEqual(
            ChargeReconciliationPolicy.mode(from: expectation),
            .discharging(target: 65, returnLimit: 80)
        )
    }

    func testActiveModeExpectationRejectsDriftAndTransitionWrappers() {
        XCTAssertNil(
            ChargeReconciliationPolicy.expectation(
                fromActiveMode: .externalDrift(
                    expected: .controlReleased(lastLimit: 80),
                    observed: .charging
                )
            )
        )
        XCTAssertNil(
            ChargeReconciliationPolicy.expectation(
                fromActiveMode: .transitioning(.startingTopUp(returnLimit: 80))
            )
        )
    }
}

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
        XCTAssertTrue(result.stdoutWasTruncated)
        XCTAssertFalse(result.stderrWasTruncated)
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
        XCTAssertTrue(result.stderrWasTruncated)
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

    func testLongRunningCommandUsesItsMonotonicTimeout() async throws {
        let runner = BatteryCommandRunner()
        _ = try await runner.launchLongRunning(
            .init(
                executable: "/bin/sh",
                arguments: termIgnoringShell,
                label: "timed long fixture",
                timeout: 0.05
            )
        )
        let deadline = Date().addingTimeInterval(3)
        var result: BatteryCommandResult?
        while result == nil, Date() < deadline {
            result = await runner.longRunningResult()
            if result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let isActive = await runner.isLongRunningActive()
        XCTAssertFalse(isActive)
        XCTAssertEqual(result?.termination, .timedOut)
    }

    func testNonFiniteTimeoutsDoNotTrapTheRunner() async throws {
        let runner = BatteryCommandRunner()
        let infiniteResult = try await runner.run(
            .init(
                executable: "/usr/bin/true",
                arguments: [],
                label: "infinite timeout fixture",
                timeout: .infinity
            )
        )
        XCTAssertEqual(infiniteResult.termination, .exited)

        let nanResult = try await runner.run(
            .init(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while true; do :; done"],
                label: "nan timeout fixture",
                timeout: .nan
            )
        )
        XCTAssertEqual(nanResult.termination, .timedOut)
    }

    func testCancelAllRejectsCommandsQueuedDuringCancellation() async throws {
        let runner = BatteryCommandRunner()
        let arguments = termIgnoringShell
        let active = Task {
            try await runner.run(
                .init(
                    executable: "/bin/sh",
                    arguments: arguments,
                    label: "active cancellation fixture",
                    timeout: 5
                )
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancellation = Task { try await runner.cancelAll() }
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            _ = try await runner.run(
                .init(executable: "/bin/true", arguments: [], label: "late command")
            )
            XCTFail("Expected enqueue to be rejected during cancellation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cancellation"))
        }

        try await cancellation.value
        _ = try await active.value
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
            maintainWorkerProbe: { _, _ in
                guard
                    let rawTarget = try? String(contentsOf: stateFile, encoding: .utf8),
                    let target = Int(rawTarget.trimmingCharacters(in: .whitespacesAndNewlines))
                else {
                    return .stopped
                }
                return .running(pid: 4_242, target: target)
            },
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
            maintainWorkerProbe: { _, _ in .running(pid: 4_242, target: 80) },
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
            maintainWorkerProbe: { _, _ in .running(pid: 4_242, target: 80) },
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

    func testReleaseControlRequiresEnabledChargingNoDischargeAndNoWorker() async throws {
        let commandLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-command-log-\(UUID().uuidString)")
        let processLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-process-log-\(UUID().uuidString)")
        let successFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf '%s\\n' "$*" >> \(shellQuote(commandLog.path))
            if [[ "$1" == "charge" ]]; then
              echo "$$" > \(shellQuote(processLog.path))
              trap '' TERM
              while true; do sleep 1; done
            fi
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,enabled,not discharging,80"
            fi
            """
        )
        let failureFixture = try makeExecutableFixture(
            """
            #!/bin/bash
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: successFixture)
            try? FileManager.default.removeItem(at: failureFixture)
            try? FileManager.default.removeItem(at: commandLog)
            if let pidText = try? String(contentsOf: processLog).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidText) {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: processLog)
        }

        let successBackend = SMCKit(
            batteryPath: successFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )
        try await successBackend.startTopUp(to: 100)
        let processPID = try XCTUnwrap(
            Int32(String(contentsOf: processLog).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(Darwin.kill(processPID, 0), 0)

        try await successBackend.releaseBatteryGuardControl()

        let commands = try String(contentsOf: commandLog)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(commands.filter { $0 == "maintain stop" }.count, 1)
        let ownsLongRunningOperation = await successBackend.isLongRunningOperationActive()
        XCTAssertFalse(ownsLongRunningOperation)
        let processExited = await eventually {
            Darwin.kill(processPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertTrue(processExited)

        let failureBackend = SMCKit(
            batteryPath: failureFixture.path,
            maintainWorkerProbe: { _, _ in .stopped },
            executableTrustPolicy: .testFixture
        )
        do {
            try await failureBackend.releaseBatteryGuardControl()
            XCTFail("Expected released-control verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("released control"))
        }
    }

    func testBatteryCLIUsesOnlyPinnedAndSystemSearchPaths() async throws {
        let environmentLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-path-log-\(UUID().uuidString)")
        let fixture = try makeExecutableFixture(
            """
            #!/bin/bash
            printf '%s' "$PATH" > \(shellQuote(environmentLog.path))
            if [[ "$1" == "status_csv" ]]; then
              echo "80,00:10,disabled,not discharging,80"
            fi
            """
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: environmentLog)
        }
        let backend = SMCKit(
            batteryPath: fixture.path,
            maintainWorkerProbe: { _, _ in .running(pid: 4_242, target: 80) },
            executableTrustPolicy: .testFixture
        )

        try await backend.applyMaintain(level: 80)

        let path = try String(contentsOf: environmentLog, encoding: .utf8)
        XCTAssertEqual(
            path,
            "\(fixture.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        )
        XCTAssertFalse(path.split(separator: ":").contains("/usr/local/bin"))
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

    func testPreflightRejectsAnUntrustedSMCBinaryBeforeExecutingBatteryCLI() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-preflight-marker-\(UUID().uuidString)")
        let batteryFixture = try makeExecutableFixture(
            "#!/bin/bash\necho invoked > \(shellQuote(marker.path))\n"
        )
        let smcTarget = try makeExecutableFixture("#!/bin/bash\nexit 0\n")
        let smcLink = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-smc-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: smcLink, withDestinationURL: smcTarget)
        defer {
            try? FileManager.default.removeItem(at: batteryFixture)
            try? FileManager.default.removeItem(at: smcTarget)
            try? FileManager.default.removeItem(at: smcLink)
            try? FileManager.default.removeItem(at: marker)
        }
        let backend = SMCKit(
            batteryPath: batteryFixture.path,
            smcBinaryPath: smcLink.path,
            executableTrustPolicy: .testFixture
        )

        do {
            try await backend.open()
            XCTFail("Expected SMC preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("preflight failed"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testMaintainVerificationRejectsUnknownChargingAndMismatchedWorkerTarget() async throws {
        let cases: [(String, MaintainWorkerStatus)] = [
            ("unknown", .running(pid: 4_242, target: 80)),
            ("disabled", .running(pid: 4_242, target: 60))
        ]
        for (chargingText, worker) in cases {
            let fixture = try makeExecutableFixture(
                """
                #!/bin/bash
                if [[ "$1" == "status_csv" ]]; then
                  echo "80,00:10,\(chargingText),not discharging,80"
                fi
                """
            )
            defer { try? FileManager.default.removeItem(at: fixture) }
            let backend = SMCKit(
                batteryPath: fixture.path,
                maintainWorkerProbe: { _, _ in worker },
                executableTrustPolicy: .testFixture
            )
            do {
                try await backend.applyMaintain(level: 80)
                XCTFail("Expected incomplete Maintain tuple to fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("status_csv reported"))
            }
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
    @MainActor
    func testAppHostedTestCompositionNeverUsesProductionState() {
        XCTAssertTrue(AppRuntime.isRunningTests)
        XCTAssertTrue(BatteryHistory.shared.usesInMemoryStore)
        XCTAssertFalse(BatteryMonitor.shared.usesMonitoringInfrastructure)
        XCTAssertFalse(UserSettings.shared.usesStandardDefaults)
        XCTAssertNil(DiagnosticLog.shared.fileURL)
    }

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
        initialMode: ChargeMode? = nil,
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
                initialMode: initialMode,
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
                maintainWorker: .running(pid: 7_777, target: 60)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertTrue(controller.hasExternalControlDrift)
        XCTAssertEqual(controller.effectiveChargeLimit, 80)
        XCTAssertTrue(controller.externalDriftDescription?.contains("기대: Maintain 80%") == true)
        XCTAssertTrue(controller.externalDriftDescription?.contains("실제: Maintain 60%") == true)
        XCTAssertTrue(controller.externalDriftDescription?.contains("60%") == true)
        XCTAssertTrue(controller.externalDriftRecoveryDescription?.contains("Maintain 80%") == true)
        XCTAssertTrue(controller.lastError?.contains("외부 CLI 변경 감지") == true)

        let driftWasLogged = await log.recentEvents().contains { $0.outcome == .drifted }
        XCTAssertTrue(driftWasLogged)

        await controller.reconcileExternalState()
        let repeatedEvents = await log.recentEvents()
        XCTAssertEqual(repeatedEvents.filter { $0.outcome == .drifted }.count, 1)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_888, target: 80)
            )
        )
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
        XCTAssertFalse(controller.hasExternalControlDrift)
        XCTAssertNil(controller.externalDriftDescription)
    }

    func testUnknownChargingNeverQualifiesAsMaintain() async {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .unknown,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertTrue(controller.hasExternalControlDrift)
        XCTAssertEqual(controller.currentState, .unknown)
        XCTAssertTrue(controller.externalDriftDescription?.contains("모순된") == true)
    }

    func testUnknownAndDuplicateWorkersNeverQualifyAsMaintain() async {
        let (controller, backend, _, _) = makeSUT()
        let invalidWorkers: [MaintainWorkerStatus] = [
            .unknown,
            .duplicate(pids: [101, 202])
        ]

        for worker in invalidWorkers {
            backend.setControlStatus(
                BatteryControlStatus(
                    charging: .disabled,
                    isDischarging: false,
                    maintainLevel: 80,
                    maintainWorker: worker
                )
            )
            await controller.reconcileExternalState()
            XCTAssertTrue(controller.hasExternalControlDrift)
        }
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
                maintainWorker: .running(pid: 6_565, target: 65)
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
            reconciliationInterval: 1
        )
        try await controller.initialize()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 70,
                maintainWorker: .running(pid: 7_070, target: 70)
            )
        )

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        try await controller.shutdown()
    }

    func testLostTopUpOwnershipSurfacesExternalDriftWithoutOverwritingIt() async {
        let (controller, backend, monitor, _) = makeSUT(charge: 70)
        controller.startTopUp()
        let topUpStarted = await eventually { controller.isTopUpActive }
        XCTAssertTrue(topUpStarted)
        backend.setOwnedLongRunningOperation(false)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .enabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        let info = makeBatteryInfo(charge: 70)
        monitor.batteryInfo = info
        controller.processBatteryInfo(info)

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
        XCTAssertTrue(controller.externalDriftDescription?.contains("실제: 충전 명령 활성") == true)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testLostDischargeOwnershipSurfacesExternalDriftWithoutOverwritingIt() async {
        let (controller, backend, monitor, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        controller.startDischarge()
        let dischargeStarted = await eventually { controller.isDischarging }
        XCTAssertTrue(dischargeStarted)
        backend.setOwnedLongRunningOperation(false)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        let info = makeBatteryInfo(charge: 90)
        monitor.batteryInfo = info
        controller.processBatteryInfo(info)

        let driftDetected = await eventually { controller.hasExternalControlDrift }
        XCTAssertTrue(driftDetected)
        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
        XCTAssertTrue(controller.externalDriftDescription?.contains("실제: 방전 명령 활성") == true)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testDischargeStartFailureRecordsMaintainAsPreviousAndBlocksIfRecoveryFails() async {
        let (controller, backend, _, settings) = makeSUT(charge: 90)
        settings.chargeLimit = 80
        backend.failNext("discharge")

        controller.startDischarge()
        let recoveredFailure = await eventually {
            if case .failed(let previous, _, let blocked) = controller.mode {
                return previous == .maintaining(limit: 80) && !blocked
            }
            return false
        }
        XCTAssertTrue(recoveredFailure)

        let (blockedController, blockedBackend, _, blockedSettings) = makeSUT(charge: 90)
        blockedSettings.chargeLimit = 80
        blockedBackend.failNext("discharge")
        blockedBackend.failNext("maintain")
        blockedController.startDischarge()
        let blockedFailure = await eventually {
            if case .failed(let previous, _, let blocked) = blockedController.mode {
                return previous == .maintaining(limit: 80) && blocked
            }
            return false
        }
        XCTAssertTrue(blockedFailure)
    }

    func testWakePreservesExternalDriftWithoutApplyingMaintain() async {
        let expectation = ReconciledChargeExpectation.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .externalDrift(
                expected: expectation,
                observed: .maintaining(limit: 60)
            )
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        await controller.reconcileAfterWake()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(expected: expectation, observed: .maintaining(limit: 60))
        )
        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
    }

    func testHeatBlockedDriftRecoversOnlyAfterChargingIsVerifiedDisabled() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(initialMode: .heatBlocked(previous: previous))
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 4_242, target: 80)
            )
        )

        await controller.reconcileExternalState()
        XCTAssertTrue(controller.hasExternalControlDrift)

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )
        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: previous))
        XCTAssertFalse(controller.hasExternalControlDrift)
    }

    func testRecoverableFailureCanReturnToVerifiedPreviousMode() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, _, _, _) = makeSUT(
            initialMode: .failed(previous: previous, message: "temporary", controlsBlocked: false)
        )

        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
    }

    func testBlockedFailureOnlyRecoversToHeatBlockedAfterDisabledTupleIsVerified() async {
        let previous = RestorableChargeMode.maintaining(limit: 80)
        let (controller, backend, _, _) = makeSUT(
            initialMode: .failed(previous: previous, message: "temporary", controlsBlocked: true)
        )
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        await controller.reconcileExternalState()

        XCTAssertEqual(controller.mode, .heatBlocked(previous: previous))
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
                maintainWorker: .running(pid: 6_060, target: 60)
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
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        try await controller.shutdown()
    }

    func testShutdownRefreshesStaleDriftAndRejectsNewExternalDischarge() async {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        await controller.reconcileExternalState()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: true,
                maintainLevel: nil,
                maintainWorker: .stopped
            )
        )

        do {
            try await controller.shutdown()
            XCTFail("Expected fresh external discharge to reject shutdown")
        } catch {
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.hasExternalControlDrift)
            XCTAssertTrue(controller.externalDriftDescription?.contains("방전 명령 활성") == true)
            XCTAssertFalse(backend.operations.contains("request-cancellation"))
        }
    }

    func testShutdownRejectsWhenFreshDriftStatusCannotBeReadAndRemainsRetryable() async throws {
        let (controller, backend, _, _) = makeSUT()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        await controller.reconcileExternalState()
        backend.failNext("read-status")

        do {
            try await controller.shutdown()
            XCTFail("Expected unavailable shutdown status to reject shutdown")
        } catch {
            XCTAssertTrue(controller.isReady)
            XCTAssertTrue(controller.hasExternalControlDrift)
            XCTAssertTrue(controller.externalDriftDescription?.contains("확인할 수 없음") == true)
            XCTAssertFalse(backend.operations.contains("request-cancellation"))
        }

        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .running(pid: 8_080, target: 80)
            )
        )
        await controller.reconcileExternalState()
        XCTAssertEqual(controller.mode, .maintaining(limit: 80))
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

    func testShutdownFailureDoesNotPretendCleanupSucceeded() async throws {
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
            XCTAssertEqual(controller.readiness, .ready)
            if case .failed(_, _, let controlsBlocked) = controller.mode {
                XCTAssertTrue(controlsBlocked)
            } else {
                XCTFail("Expected retryable failed state")
            }
        }


        try await controller.shutdown()
        XCTAssertEqual(controller.readiness, .shuttingDown)
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

    func testDisableBatteryGuardControlReleasesVerifiedControlAndPersistsMonitoringMode() async {
        let (controller, backend, _, settings) = makeSUT()
        settings.heatProtectionEnabled = true
        settings.controlMagSafeLED = true

        controller.disableBatteryGuardControl()

        let released = await eventually {
            controller.mode == .controlDisabled(lastLimit: 80)
        }
        XCTAssertTrue(released)
        XCTAssertTrue(backend.operations.contains("release-control"))
        XCTAssertFalse(settings.batteryControlEnabled)
        XCTAssertFalse(settings.heatProtectionEnabled)
        XCTAssertFalse(settings.controlMagSafeLED)
    }

    func testDisableBatteryGuardControlFailurePreservesReleasingOwnershipAndRetryPath() async {
        let (controller, backend, _, settings) = makeSUT()
        backend.failNext("release-control")

        controller.disableBatteryGuardControl()

        let failed = await eventually {
            if case .externalDrift(.controlReleasing(lastLimit: 80), .unavailable) = controller.mode {
                return true
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(settings.batteryControlEnabled)
        XCTAssertTrue(settings.batteryControlReleasePending)
        XCTAssertTrue(controller.isReleasedControlDrift)
    }

    func testDisableTransitionImmediatelyBlocksControllerOwnedFeatures() async {
        let (controller, backend, _, settings) = makeSUT()
        settings.heatProtectionEnabled = true
        backend.releaseDelay = 0.2

        controller.disableBatteryGuardControl()

        XCTAssertEqual(settings.batteryControlOwnership, .releasing(lastLimit: 80))
        XCTAssertTrue(controller.isBatteryControlDisabled)
        controller.setHeatProtectionEnabled(false)
        controller.setHeatProtectionEnabled(true)
        XCTAssertFalse(settings.heatProtectionEnabled)

        let released = await eventually { controller.mode == .controlDisabled(lastLimit: 80) }
        XCTAssertTrue(released)
        XCTAssertFalse(settings.heatProtectionEnabled)
    }

    func testShutdownCannotInvertOwnershipAfterReleaseWasDurablyCommitted() async throws {
        let (controller, backend, _, settings) = makeSUT()
        controller.setLEDControlEnabled(true)
        let ledWasCaptured = await eventually { backend.operations.contains("set-led:03") }
        XCTAssertTrue(ledWasCaptured)
        backend.restoreLEDDelay = 0.2

        controller.disableBatteryGuardControl()
        let releaseWasCommitted = await eventually {
            settings.batteryControlOwnership == .system(lastLimit: 80)
        }
        XCTAssertTrue(releaseWasCommitted)

        try await controller.shutdown()

        XCTAssertEqual(settings.batteryControlOwnership, .system(lastLimit: 80))
        XCTAssertEqual(controller.readiness, .shuttingDown)
        XCTAssertFalse(settings.batteryControlReleasePending)
    }

    func testEnableBatteryGuardControlEstablishesMaintainBeforePersistingOwnership() async throws {
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 75)
        )
        try settings.completeBatteryControlRelease(lastLimit: 75)

        controller.enableBatteryGuardControl()

        let enabled = await eventually { controller.mode == .maintaining(limit: 75) }
        XCTAssertTrue(enabled)
        XCTAssertTrue(backend.operations.contains("maintain:75"))
        XCTAssertTrue(settings.batteryControlEnabled)
        XCTAssertEqual(settings.batteryControlOwnership, .batteryGuard(lastLimit: 75))
    }

    func testEnableBatteryGuardControlFailurePreservesSystemOwnershipTruth() async throws {
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 75)
        )
        try settings.completeBatteryControlRelease(lastLimit: 75)
        backend.failNext("maintain")

        controller.enableBatteryGuardControl()

        let failed = await eventually {
            if case .externalDrift(.controlReleased(lastLimit: 75), .unavailable) = controller.mode {
                return true
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(settings.batteryControlOwnership, .system(lastLimit: 75))
        XCTAssertTrue(controller.isBatteryControlDisabled)
    }

    func testInitializationResumesPendingReleaseWithoutApplyingMaintain() async throws {
        let backend = FakeChargeBackend()
        let info = makeBatteryInfo(charge: 70, isCharging: true)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        try settings.beginBatteryControlRelease(lastLimit: 80)
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings
        )

        try await controller.initialize()

        XCTAssertEqual(controller.mode, .controlDisabled(lastLimit: 80))
        XCTAssertFalse(settings.batteryControlEnabled)
        XCTAssertFalse(settings.batteryControlReleasePending)
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
        XCTAssertTrue(backend.operations.contains("release-control"))
        try await controller.shutdown()
    }

    func testInitializationOfSystemOwnershipAllowsNativePauseAndClearsControlSideEffects() async throws {
        let backend = FakeChargeBackend()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .stopped
            )
        )
        let monitor = BatteryMonitor(
            batteryInfoProvider: { nil },
            runsMonitoringInfrastructure: false
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        try settings.completeBatteryControlRelease(lastLimit: 80)
        settings.heatProtectionEnabled = true
        settings.controlMagSafeLED = true
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings
        )

        try await controller.initialize()

        XCTAssertEqual(controller.mode, .controlDisabled(lastLimit: 80))
        XCTAssertFalse(settings.heatProtectionEnabled)
        XCTAssertFalse(settings.controlMagSafeLED)
        XCTAssertFalse(backend.operations.contains("release-control"))
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
        try await controller.shutdown()
    }

    func testCorruptOwnershipJournalBlocksInitializationBeforeBackendOpen() async {
        let journalURL = makeOwnershipJournalURL()
        defer { try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent()) }
        try? FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("not-json".utf8).write(to: journalURL)
        let backend = FakeChargeBackend()
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService(),
            batteryControlOwnershipJournalURL: journalURL
        )
        let controller = ChargeController(
            backend: backend,
            monitor: BatteryMonitor(
                batteryInfoProvider: { makeBatteryInfo() },
                runsMonitoringInfrastructure: false
            ),
            settings: settings
        )

        do {
            try await controller.initialize()
            XCTFail("Expected corrupt ownership journal to block initialization")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("소유권 기록"))
        }
        XCTAssertFalse(backend.operations.contains("open"))
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
    }

    func testReleasedControlReconciliationReportsExternalMaintainAsDrift() async throws {
        let expectation = ReconciledChargeExpectation.controlReleased(lastLimit: 80)
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 80)
        )
        try settings.completeBatteryControlRelease(lastLimit: 80)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )

        await controller.reconcileExternalState()

        XCTAssertEqual(
            controller.mode,
            .externalDrift(expected: expectation, observed: .maintaining(limit: 60))
        )
        XCTAssertTrue(controller.isBatteryControlDisabled)
    }

    func testPendingReleaseRestartNeverReclaimsControlFromObservedMaintain() async throws {
        let backend = FakeChargeBackend()
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 60,
                maintainWorker: .running(pid: 6_060, target: 60)
            )
        )
        let info = makeBatteryInfo(charge: 70)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { info },
            runsMonitoringInfrastructure: false
        )
        monitor.batteryInfo = info
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        try settings.beginBatteryControlRelease(lastLimit: 80)
        backend.failNext("release-control")
        let controller = ChargeController(
            backend: backend,
            monitor: monitor,
            settings: settings
        )

        try await controller.initialize()

        if case .externalDrift(let expectation, .unavailable) = controller.mode {
            XCTAssertEqual(expectation, .controlReleasing(lastLimit: 80))
        } else {
            XCTFail("Expected retryable released-control drift")
        }
        XCTAssertFalse(backend.operations.contains(where: { $0.hasPrefix("maintain:") }))
        XCTAssertTrue(settings.batteryControlReleasePending)

        await controller.reconcileExternalState()
        if case .externalDrift(let expectation, .maintaining(limit: 60)) = controller.mode {
            XCTAssertEqual(expectation, .controlReleasing(lastLimit: 80))
        } else {
            XCTFail("Periodic reconciliation must not claim a pending release completed")
        }
        XCTAssertTrue(settings.batteryControlReleasePending)

        await controller.reconcileAfterWake()
        if case .externalDrift(let expectation, .maintaining(limit: 60)) = controller.mode {
            XCTAssertEqual(expectation, .controlReleasing(lastLimit: 80))
        } else {
            XCTFail("Wake reconciliation must preserve pending release ownership")
        }
        XCTAssertTrue(settings.batteryControlReleasePending)

        backend.setControlStatus(nil)
        controller.disableBatteryGuardControl()
        let retrySucceeded = await eventually {
            controller.mode == .controlDisabled(lastLimit: 80)
        }
        XCTAssertTrue(retrySucceeded)
        XCTAssertFalse(settings.batteryControlReleasePending)
        try await controller.shutdown()
    }

    func testWakeAndShutdownKeepReleasedControlReadOnly() async throws {
        let (controller, backend, _, settings) = makeSUT(
            initialMode: .controlDisabled(lastLimit: 80)
        )
        try settings.completeBatteryControlRelease(lastLimit: 80)
        backend.setControlStatus(
            BatteryControlStatus(
                charging: .disabled,
                isDischarging: false,
                maintainLevel: 80,
                maintainWorker: .stopped
            )
        )
        let maintainCount = backend.operations.filter { $0.hasPrefix("maintain:") }.count

        await controller.reconcileAfterWake()
        try await controller.shutdown()

        XCTAssertEqual(
            backend.operations.filter { $0.hasPrefix("maintain:") }.count,
            maintainCount
        )
        XCTAssertFalse(backend.operations.contains("release-control"))
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
