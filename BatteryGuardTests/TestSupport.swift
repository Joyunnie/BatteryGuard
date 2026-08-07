import XCTest
import ServiceManagement
import Combine
import Darwin
import AppKit
@testable import BatteryGuard

private final class EphemeralTestDefaults: UserDefaults, @unchecked Sendable {
    private let suite: String

    init() {
        suite = "com.jiwon.batteryguard.tests.\(UUID().uuidString)"
        super.init(suiteName: suite)!
        removePersistentDomain(forName: suite)
    }

    deinit {
        removePersistentDomain(forName: suite)
    }
}

func makeTestDefaults() -> UserDefaults {
    EphemeralTestDefaults()
}

func makeOwnershipJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("batteryguard-ownership-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("ownership.json", isDirectory: false)
}

final class TestClock: @unchecked Sendable {
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

final class TestBatteryInfoSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BatteryInfo?

    init(_ value: BatteryInfo?) {
        self.value = value
    }

    func read() -> BatteryInfo? {
        lock.withLock { value }
    }

    func set(_ value: BatteryInfo?) {
        lock.withLock { self.value = value }
    }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

func makeExecutableFixture(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("batteryguard-fixture-\(UUID().uuidString)")
    try Data(contents.utf8).write(to: url, options: .atomic)
    guard Darwin.chmod(url.path, mode_t(S_IRUSR | S_IWUSR | S_IXUSR)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return url
}

final class FakeLaunchAtLoginService: LaunchAtLoginManaging {
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

@MainActor
final class FakeSystemPowerObserver: SystemPowerObserving {
    var startError: Error?
    var requiresChargingDisabledForSleepTransition = false
    private(set) var didStart = false
    private(set) var didStop = false
    private var sleepHandler: (@MainActor (UInt64) async -> Bool)?
    private var wakeHandler: (@MainActor () -> Void)?

    func start(
        willSleep: @escaping @MainActor (UInt64) async -> Bool,
        didWake: @escaping @MainActor () -> Void
    ) throws {
        if let startError { throw startError }
        didStart = true
        sleepHandler = willSleep
        wakeHandler = didWake
    }

    func stop() {
        didStop = true
        sleepHandler = nil
        wakeHandler = nil
        requiresChargingDisabledForSleepTransition = false
    }

    func resolvePendingSleepRequestsForShutdown() {
    }

    func sendSleep() async -> Bool {
        await sleepHandler?(UInt64.max) ?? true
    }

    func sendWake() {
        wakeHandler?()
    }
}

final class FakeSystemPowerTransport: SystemPowerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var decisionsStorage: [(Int, SleepAcknowledgementDecision)] = []
    private var handler: (@MainActor (UInt32, Int) -> Void)?

    var decisions: [(Int, SleepAcknowledgementDecision)] {
        lock.withLock { decisionsStorage }
    }

    @MainActor
    func start(
        handler: @escaping @MainActor (_ messageType: UInt32, _ token: Int) -> Void
    ) throws {
        self.handler = handler
    }

    func resolve(token: Int, decision: SleepAcknowledgementDecision) {
        lock.withLock { decisionsStorage.append((token, decision)) }
    }

    @MainActor
    func stop() {
        handler = nil
    }

    @MainActor
    func send(messageType: UInt32, token: Int = 1) {
        handler?(messageType, token)
    }
}

final class FakeChargeBackend: ChargeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOperations: [String] = []
    private var failures: [String: Error] = [:]
    private var longRunning = false
    private var discharging = false
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
    private var temperatureReadDelays: [TimeInterval] = []
    private var ignoresTemperatureReadCancellation = false
    private var ledDelayByRawValue: [UInt8: TimeInterval] = [:]
    private var controlStatusOverride: BatteryControlStatus?
    private var controlStatusDelayValue: TimeInterval = 0
    private var longRunningProbeDelayValue: TimeInterval = 0
    private var cancelLongRunningDelayValue: TimeInterval = 0
    private var ignoresCancelLongRunningCancellation = false

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

    func clearOperations() {
        lock.withLock { recordedOperations.removeAll() }
    }

    func enqueueTemperatures(_ values: [Float?]) {
        lock.withLock { temperatureSequence.append(contentsOf: values) }
    }

    func enqueueTemperatureReadDelays(
        _ delays: [TimeInterval],
        ignoringCancellation: Bool = false
    ) {
        lock.withLock {
            temperatureReadDelays.append(contentsOf: delays)
            ignoresTemperatureReadCancellation = ignoringCancellation
        }
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

    func setLongRunningProbeDelay(_ delay: TimeInterval) {
        lock.withLock { longRunningProbeDelayValue = delay }
    }

    func setCancelLongRunningDelay(
        _ delay: TimeInterval,
        ignoringCancellation: Bool = false
    ) {
        lock.withLock {
            cancelLongRunningDelayValue = delay
            ignoresCancelLongRunningCancellation = ignoringCancellation
        }
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
                isDischarging: discharging,
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
            discharging = false
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
            discharging = false
            maintainWorkerRunning = false
            chargingStatus = .enabled
        }
    }

    func disableCharging() async throws {
        try record("disable-charging")
        let longOperationIsActive = lock.withLock {
            chargingStatus = .disabled
            discharging = false
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
            chargingStatus = .enabled
            discharging = true
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
            discharging = false
            longRunning = true
        }
    }

    func isLongRunningOperationActive() async -> Bool {
        let probe = lock.withLock { () -> (Bool, TimeInterval) in
            recordedOperations.append("check-long-running")
            return (longRunning, longRunningProbeDelayValue)
        }
        if probe.1 > 0 {
            try? await Task.sleep(nanoseconds: UInt64(probe.1 * 1_000_000_000))
        }
        return probe.0
    }

    func longRunningOperationResult() async -> BatteryCommandResult? { nil }

    func cancelLongRunningOperation() async throws {
        try record("cancel-long")
        let delay = lock.withLock {
            (cancelLongRunningDelayValue, ignoresCancelLongRunningCancellation)
        }
        if delay.0 > 0 {
            if delay.1 {
                await Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(delay.0 * 1_000_000_000))
                }.value
            } else {
                try await Task.sleep(nanoseconds: UInt64(delay.0 * 1_000_000_000))
            }
        }
        setLongRunning(false)
    }

    func prepareForSystemSleep(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> BatteryControlStatus {
        try record("prepare-system-sleep")
        let delay = lock.withLock {
            (cancelLongRunningDelayValue, ignoresCancelLongRunningCancellation)
        }
        if delay.0 > 0 {
            if delay.1 {
                await Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(delay.0 * 1_000_000_000))
                }.value
            } else {
                try await Task.sleep(nanoseconds: UInt64(delay.0 * 1_000_000_000))
            }
        }
        if let error = lock.withLock({ failures["prepare-system-sleep"] }) {
            throw error
        }
        if let deadlineUptimeNanoseconds,
           DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds {
            throw BatteryError.commandFailed("prepare system sleep", -1, "deadline exceeded")
        }
        setLongRunning(false)
        lock.withLock {
            guard controlStatusOverride == nil else { return }
            chargingStatus = .disabled
            discharging = false
            maintainWorkerRunning = false
        }
        return try await readControlStatus()
    }

    func requestCancellation() async throws {
        try record("request-cancellation")
        setLongRunning(false)
    }

    func readBatteryTemperature() async throws -> Float {
        try record("read-temperature")
        let read = lock.withLock {
            let temperature = temperatureSequence.isEmpty ? temperatureValue : temperatureSequence.removeFirst()
            let delay = temperatureReadDelays.isEmpty ? 0 : temperatureReadDelays.removeFirst()
            return (temperature, delay, ignoresTemperatureReadCancellation)
        }
        if read.1 > 0 {
            if read.2 {
                await Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(read.1 * 1_000_000_000))
                }.value
            } else {
                try await Task.sleep(nanoseconds: UInt64(read.1 * 1_000_000_000))
            }
        }
        guard let nextTemperature = read.0 else {
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
        if !value { discharging = false }
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

func makeBatteryInfo(
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
