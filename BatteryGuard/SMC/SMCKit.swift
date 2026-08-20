// SMCKit.swift
// Semantic battery operations layered over BatteryCommandRunner.

import Foundation
import Darwin

let defaultBatteryPath = "/usr/local/co.palokaj.battery/battery"
let defaultSMCBinaryPath = "/usr/local/co.palokaj.battery/smc"
private let bundledTemperatureReaderName = "BatteryGuardSMCReader"
private let defaultSMCTemperatureReadTimeout: TimeInterval = 2
private let defaultSMCTemperatureTotalBudget: TimeInterval = 4.5
private let defaultTemperatureReaderRetryDelay: TimeInterval = 60
let maximumMaintainWorkerCandidates = 32

func bundledTemperatureReaderPath() -> String {
    Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers", isDirectory: true)
        .appendingPathComponent(bundledTemperatureReaderName, isDirectory: false)
        .path
}

actor AsyncOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum MagSafeLEDState: UInt8, Equatable, Sendable {
    case green = 0x03
    case orange = 0x04
}

enum BatteryError: Error, LocalizedError, CustomStringConvertible {
    case binaryNotFound(String)
    case invalidChargeLevel(Int)
    case unsupported(String)
    case ownershipPersistenceFailed(String)
    case preflightFailed(String)
    case commandCancelled(String)
    case commandTimedOut(String)
    case commandFailed(String, Int32, String)

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            return "Binary not found at \(path)"
        case .invalidChargeLevel(let level):
            return "Charge level must be between 20 and 100, received \(level)"
        case .unsupported(let message):
            return message
        case .ownershipPersistenceFailed(let message):
            return message
        case .preflightFailed(let message):
            return "Battery CLI preflight failed: \(message)"
        case .commandCancelled(let command):
            return "Command cancelled: \(command)"
        case .commandTimedOut(let command):
            return "Command timed out: \(command)"
        case .commandFailed(let command, let code, let output):
            return "Command failed (\(code)): \(command) — \(output)"
        }
    }

    var errorDescription: String? { description }
}

enum BatteryChargingStatus: Equatable, Sendable {
    case enabled
    case disabled
    case unknown
}

enum MaintainWorkerStatus: Equatable, Sendable {
    case running(pid: Int32, target: Int?)
    case stopped
    case stale(pid: Int32?)
    case duplicate(pids: [Int32])
    case unknown

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isStopped: Bool { self == .stopped }

    func matches(level: Int) -> Bool {
        guard case .running(_, let target) = self else { return false }
        return target == level
    }
}

struct BatteryControlStatus: Equatable, Sendable {
    let charging: BatteryChargingStatus
    let isDischarging: Bool?
    let maintainLevel: Int?
    let maintainWorker: MaintainWorkerStatus

    init(
        charging: BatteryChargingStatus,
        isDischarging: Bool?,
        maintainLevel: Int?,
        maintainWorker: MaintainWorkerStatus = .unknown
    ) {
        self.charging = charging
        self.isDischarging = isDischarging
        self.maintainLevel = maintainLevel
        self.maintainWorker = maintainWorker
    }

    var diagnosticDescription: String {
        "charging=\(charging.diagnosticLabel),discharging=\(isDischarging.map(String.init) ?? "unknown"),maintain=\(maintainLevel.map(String.init) ?? "unknown"),worker=\(maintainWorker.diagnosticLabel)"
    }

    func isVerifiedMaintain(level: Int) -> Bool {
        charging != .unknown &&
            isDischarging == false &&
            maintainLevel == level &&
            maintainWorker.matches(level: level)
    }

    var isVerifiedChargingDisabled: Bool {
        charging == .disabled &&
            isDischarging == false &&
            maintainWorker.isStopped
    }

    var isVerifiedDischarging: Bool {
        charging == .enabled &&
            isDischarging == true &&
            maintainWorker.isStopped
    }

    var isVerifiedControlReleased: Bool {
        charging == .enabled &&
            isDischarging == false &&
            maintainWorker.isStopped
    }

    var isCompatibleWithReleasedControl: Bool {
        charging != .unknown &&
            isDischarging == false &&
            maintainWorker.isStopped
    }
}

struct BatteryTemperatureSample: Equatable, Sendable {
    let maximum: Float
    let failures: [String]

    var hasCompleteCoverage: Bool { failures.isEmpty }

    static func complete(_ maximum: Float) -> BatteryTemperatureSample {
        BatteryTemperatureSample(maximum: maximum, failures: [])
    }
}

private extension BatteryChargingStatus {
    var diagnosticLabel: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .unknown: return "unknown"
        }
    }
}

private extension MaintainWorkerStatus {
    var diagnosticLabel: String {
        switch self {
        case .running(let pid, let target):
            return "running(\(pid),target:\(target.map(String.init) ?? "unknown"))"
        case .stopped: return "stopped"
        case .stale(let pid): return "stale(\(pid.map(String.init) ?? "unknown"))"
        case .duplicate(let pids): return "duplicate(\(pids.map(String.init).joined(separator: ",")))"
        case .unknown: return "unknown"
        }
    }
}

protocol ChargeControlBackend: AnyObject, Sendable {
    func open() async throws
    func readControlStatus() async throws -> BatteryControlStatus
    func applyMaintain(level: Int) async throws
    func releaseBatteryGuardControl() async throws
    func disableCharging() async throws
    func prepareForSystemSleep(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> BatteryControlStatus
    func verifyChargingDisabledForSystemSleep(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> BatteryControlStatus
    func startDischarge(to level: Int) async throws
    func startTopUp(to level: Int) async throws
    func isLongRunningOperationActive() async -> Bool
    func longRunningOperationResult() async -> BatteryCommandResult?
    func waitForLongRunningOperationExit() async -> BatteryCommandResult?
    func cancelLongRunningOperation() async throws
    func requestCancellation() async throws
}

protocol BatteryTemperatureBackend: AnyObject, Sendable {
    func readBatteryTemperature() async throws -> BatteryTemperatureSample
}

protocol MagSafeLEDBackend: AnyObject, Sendable {
    func setMagSafeLED(_ state: MagSafeLEDState) async throws
    func restoreMagSafeLED() async throws
}

/// Composite application seam. Narrow consumers should depend on one of the
/// capability protocols above instead of receiving every hardware mutation.
protocol ChargeBackend: ChargeControlBackend, BatteryTemperatureBackend, MagSafeLEDBackend {}

actor SMCKit: ChargeBackend {
    typealias MaintainWorkerProbe = @Sendable (_ pidFilePath: String, _ batteryPath: String) async throws -> MaintainWorkerStatus
    typealias MonotonicNow = @Sendable () -> UInt64
    typealias MonotonicSleepUntil = @Sendable (_ deadlineUptimeNanoseconds: UInt64) async throws -> Void

    enum ExecutableTrustPolicy: Sendable, Equatable {
        case production
        case testFixture
    }

    static let shared = SMCKit(
        runner: BatteryCommandRunner(diagnostics: .shared),
        temperatureReaderPath: bundledTemperatureReaderPath(),
        diagnostics: .shared
    )

    // Internal only so implementation extensions in sibling files can share
    // the actor's single runner, gates, and verified executable state.
    let runner: BatteryCommandRunner
    let controlGate = AsyncOperationGate()
    private let ledGate = AsyncOperationGate()
    let batteryPath: String
    let smcBinaryPath: String
    let temperatureReaderPath: String?
    private let usesSudoForSMCWrites: Bool
    let maintainPIDFilePath: String
    let maintainWorkerProbe: MaintainWorkerProbe?
    let executableTrustPolicy: ExecutableTrustPolicy
    let diagnostics: DiagnosticLog
    let smcTemperatureReadTimeout: TimeInterval
    let smcTemperatureTotalBudget: TimeInterval
    let temperatureReaderRetryDelay: TimeInterval
    let sleepStatusSettlementBackoffs: [UInt64]
    let monotonicNow: MonotonicNow
    let monotonicSleepUntil: MonotonicSleepUntil
    let statusCommandTimeout: TimeInterval = 2
    private let longRunningVerificationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private let longRunningVerificationPollNanoseconds: UInt64 = 100_000_000
    private let longRunningOperationTimeout: TimeInterval = 12 * 60 * 60
    var rawSMCAvailable = false
    private var savedMagSafeLEDValue: UInt8?
    var batteryExecutableIdentity: ExecutableIdentity?
    var smcExecutableIdentity: ExecutableIdentity?
    var temperatureReaderExecutableIdentity: ExecutableIdentity?
    var bundledTemperatureReaderState: TemperatureSourceState = .untested
    var batchedTemperatureReaderState: TemperatureSourceState = .untested

    enum TemperatureSourceState: Equatable, Sendable {
        case untested
        case available
        case retryAfter(UInt64)
        case incompatible(String)

        func shouldAttempt(at uptimeNanoseconds: UInt64) -> Bool {
            switch self {
            case .untested, .available:
                return true
            case .retryAfter(let retryAt):
                return uptimeNanoseconds >= retryAt
            case .incompatible:
                return false
            }
        }
    }

    struct BatteryTemperatureReadings {
        let valuesByKey: [String: Float]
        var maximum: Float? { valuesByKey.values.max() }
        var hasCompleteCoverage: Bool {
            Set(valuesByKey.keys) == Set(["TB0T", "TB1T", "TB2T"])
        }
    }

    struct ExecutableIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let owner: uid_t
        let group: gid_t
        let mode: mode_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    struct MaintainWorkerProcess: Equatable, Sendable {
        let pid: Int32
        let command: String
        let target: Int?
        let identity: ProcessIdentity?
    }

    struct ProcessIdentity: Equatable, Sendable {
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct ParsedMaintainCommand: Equatable, Sendable {
        let target: Int?
    }

    init(
        runner: BatteryCommandRunner = BatteryCommandRunner(),
        batteryPath: String = defaultBatteryPath,
        smcBinaryPath: String = defaultSMCBinaryPath,
        temperatureReaderPath: String? = nil,
        usesSudoForSMCWrites: Bool = true,
        maintainPIDFilePath: String? = nil,
        maintainWorkerProbe: MaintainWorkerProbe? = nil,
        executableTrustPolicy: ExecutableTrustPolicy = .production,
        smcTemperatureReadTimeout: TimeInterval = defaultSMCTemperatureReadTimeout,
        smcTemperatureTotalBudget: TimeInterval = defaultSMCTemperatureTotalBudget,
        temperatureReaderRetryDelay: TimeInterval = defaultTemperatureReaderRetryDelay,
        sleepStatusSettlementBackoffs: [UInt64] = [
            100_000_000,
            250_000_000,
            500_000_000,
            1_000_000_000
        ],
        monotonicNow: @escaping MonotonicNow = { DispatchTime.now().uptimeNanoseconds },
        monotonicSleepUntil: @escaping MonotonicSleepUntil = { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                try await Task.sleep(nanoseconds: deadline - now)
            }
        },
        diagnostics: DiagnosticLog = .disabled
    ) {
        self.runner = runner
        self.batteryPath = batteryPath
        self.smcBinaryPath = smcBinaryPath
        self.temperatureReaderPath = temperatureReaderPath
        self.usesSudoForSMCWrites = usesSudoForSMCWrites
        if let maintainPIDFilePath {
            self.maintainPIDFilePath = maintainPIDFilePath
        } else if executableTrustPolicy == .testFixture {
            self.maintainPIDFilePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("batteryguard-test-\(UUID().uuidString).pid")
                .path
        } else {
            self.maintainPIDFilePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".battery/battery.pid")
                .path
        }
        self.maintainWorkerProbe = maintainWorkerProbe
        self.executableTrustPolicy = executableTrustPolicy
        self.smcTemperatureReadTimeout = max(0.05, smcTemperatureReadTimeout)
        self.smcTemperatureTotalBudget = max(0.05, smcTemperatureTotalBudget)
        self.temperatureReaderRetryDelay = max(0, temperatureReaderRetryDelay)
        self.sleepStatusSettlementBackoffs = sleepStatusSettlementBackoffs
        self.monotonicNow = monotonicNow
        self.monotonicSleepUntil = monotonicSleepUntil
        self.diagnostics = diagnostics
    }

    // MARK: - Verified charge operations

    func applyMaintain(level: Int) async throws {
        let operationID = DiagnosticContext.operationID ?? UUID()
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await withGate(controlGate) {
                try await applyMaintainUnlocked(level: level)
            }
        }
    }

    private func applyMaintainUnlocked(level: Int) async throws {
        try validateChargeLevel(level)
        let before = await readPreOperationStatus()
        if executableTrustPolicy == .production,
           let current = before,
           current.isVerifiedMaintain(level: level) {
            await recordVerifiedOperation("maintain \(level)", before: current, after: current)
            return
        }
        try await terminateMaintainWorkersUnlocked()
        _ = try await batteryCommand(
            ["maintain", "\(level)"],
            outputPolicy: .discardStdoutCaptureStderr,
            descendantPolicy: .allowPersistentProcessGroup
        )

        let status = try await readControlStatusUnlocked()
        guard status.isVerifiedMaintain(level: level) else {
            do {
                try await terminateMaintainWorkersUnlocked()
            } catch {
                throw BatteryError.commandFailed(
                    "battery maintain \(level)",
                    -1,
                    "verification failed: \(status.diagnosticDescription); cleanup failed: \(error.localizedDescription)"
                )
            }
            throw BatteryError.commandFailed(
                "battery maintain \(level)",
                -1,
                "status_csv reported \(status.diagnosticDescription)"
            )
        }
        await recordVerifiedOperation("maintain \(level)", before: before, after: status)
    }

    func releaseBatteryGuardControl() async throws {
        let operationID = DiagnosticContext.operationID ?? UUID()
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await withGate(controlGate) {
                let before = await readPreOperationStatus()
                _ = try await runner.cancelLongRunning()
                try await terminateMaintainWorkersUnlocked()
                _ = try await batteryCommand(["maintain", "stop"])
                let status = try await readControlStatusUnlocked()
                guard status.isVerifiedControlReleased else {
                    throw BatteryError.commandFailed(
                        "release BatteryGuard control",
                        -1,
                        "status_csv did not confirm released control: \(status.diagnosticDescription)"
                    )
                }
                await recordVerifiedOperation(
                    "release BatteryGuard control",
                    before: before,
                    after: status
                )
            }
        }
    }

    func disableCharging() async throws {
        let operationID = DiagnosticContext.operationID ?? UUID()
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await withGate(controlGate) {
                try await disableChargingUnlocked()
            }
        }
    }

    func prepareForSystemSleep(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> BatteryControlStatus {
        let operationID = DiagnosticContext.operationID ?? UUID()
        return try await DiagnosticContext.$operationID.withValue(operationID) {
            // Cancel the shared runner before entering the semantic gate so an
            // in-flight Top Up/Discharge cannot hold the gate indefinitely.
            try await runner.cancelAll()
            try ensureSleepPreparationDeadline(deadlineUptimeNanoseconds)
            return try await withGate(controlGate) {
                try ensureSleepPreparationDeadline(deadlineUptimeNanoseconds)
                let before = await readPreOperationStatus(
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
                try await terminateMaintainWorkersUnlocked(
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
                _ = try await batteryCommand(
                    ["charging", "off"],
                    timeout: try boundedSleepPreparationTimeout(
                        maximum: 8,
                        deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                    )
                )
                let status = try await verifyChargingDisabledUntilSettled(
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
                await recordVerifiedOperation(
                    "prepare battery for system sleep",
                    before: before,
                    after: status
                )
                return status
            }
        }
    }

    private func disableChargingUnlocked() async throws {
        let before = await readPreOperationStatus()
        try await terminateMaintainWorkersUnlocked()
        _ = try await batteryCommand(["charging", "off"])
        let status = try await readControlStatusUnlocked()
        guard status.isVerifiedChargingDisabled else {
            throw BatteryError.commandFailed(
                "battery charging off",
                -1,
                "status_csv did not confirm fully disabled control: \(status.diagnosticDescription)"
            )
        }
        await recordVerifiedOperation("disable charging", before: before, after: status)
    }

    func startDischarge(to level: Int) async throws {
        let operationID = DiagnosticContext.operationID ?? UUID()
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await withGate(controlGate) {
                try validateChargeLevel(level)
                let before = await readPreOperationStatus()
                try await terminateMaintainWorkersUnlocked()
                let label = "battery discharge \(level)"
                try await launchLongRunning(["discharge", "\(level)"], label: label)
                let after = try await verifyLongRunningStart(command: label) {
                    $0.isVerifiedDischarging
                }
                await recordVerifiedOperation("start discharge \(level)", before: before, after: after)
            }
        }
    }

    func startTopUp(to level: Int) async throws {
        let operationID = DiagnosticContext.operationID ?? UUID()
        try await DiagnosticContext.$operationID.withValue(operationID) {
            try await withGate(controlGate) {
                try validateChargeLevel(level)
                let before = await readPreOperationStatus()
                try await terminateMaintainWorkersUnlocked()
                let label = "battery charge \(level)"
                try await launchLongRunning(["charge", "\(level)"], label: label)
                let after = try await verifyLongRunningStart(command: label) {
                    $0.charging == .enabled &&
                        $0.isDischarging == false &&
                        $0.maintainWorker.isStopped
                }
                await recordVerifiedOperation("start Top Up \(level)", before: before, after: after)
            }
        }
    }

    func isLongRunningOperationActive() async -> Bool {
        await runner.isLongRunningActive()
    }

    func longRunningOperationResult() async -> BatteryCommandResult? {
        await runner.longRunningResult()
    }

    func waitForLongRunningOperationExit() async -> BatteryCommandResult? {
        await runner.waitForLongRunningResult()
    }

    func cancelLongRunningOperation() async throws {
        try await withGate(controlGate) {
            _ = try await runner.cancelLongRunning()
        }
    }

    func requestCancellation() async throws {
        // Deliberately bypass the semantic gate so safety preemption can stop
        // the process currently owned by the gate before waiting for it.
        try await runner.cancelAll()
    }

    // MARK: - MagSafe LED

    func setMagSafeLED(_ state: MagSafeLEDState) async throws {
        try await withGate(ledGate) {
            try await setMagSafeLEDUnlocked(state)
        }
    }

    private func setMagSafeLEDUnlocked(_ state: MagSafeLEDState) async throws {
        guard rawSMCAvailable else {
            throw BatteryError.unsupported("Raw SMC binary is unavailable; MagSafe LED control is disabled")
        }

        let needsSnapshot = savedMagSafeLEDValue == nil

        if needsSnapshot {
            let original = try await readSMCByte(key: "ACLC")
            if savedMagSafeLEDValue == nil { savedMagSafeLEDValue = original }
        }

        try await smcWrite(key: "ACLC", value: state.rawValue)
    }

    func restoreMagSafeLED() async throws {
        try await withGate(ledGate) {
            try await restoreMagSafeLEDUnlocked()
        }
    }

    private func restoreMagSafeLEDUnlocked() async throws {
        let original = savedMagSafeLEDValue

        guard let original else { return }
        guard rawSMCAvailable else {
            throw BatteryError.unsupported("Raw SMC binary is unavailable; saved MagSafe LED state cannot be restored")
        }

        try await smcWrite(key: "ACLC", value: original)
        if savedMagSafeLEDValue == original { savedMagSafeLEDValue = nil }
    }

    private func readSMCByte(key: String) async throws -> UInt8 {
        try revalidateExecutableIdentity(
            path: smcBinaryPath,
            expected: smcExecutableIdentity,
            displayName: "SMC binary"
        )
        let result = try await runProcess(
            executable: smcBinaryPath,
            arguments: ["-k", key, "-r"],
            label: "smc -k \(key) -r"
        )
        guard let bytesRange = result.stdout.range(of: "(bytes "),
              let closing = result.stdout[bytesRange.upperBound...].firstIndex(of: ")") else {
            throw BatteryError.commandFailed("smc -k \(key) -r", -1, "unexpected output: \(result.stdout)")
        }

        let bytes = result.stdout[bytesRange.upperBound..<closing]
            .split(whereSeparator: \Character.isWhitespace)
        guard let first = bytes.first, let value = UInt8(first, radix: 16) else {
            throw BatteryError.commandFailed("smc -k \(key) -r", -1, "could not parse byte value")
        }
        return value
    }

    private func smcWrite(key: String, value: UInt8) async throws {
        try revalidateExecutableIdentity(
            path: smcBinaryPath,
            expected: smcExecutableIdentity,
            displayName: "SMC binary"
        )
        let hex = String(format: "%02x", value)
        let result = try await runProcess(
            executable: usesSudoForSMCWrites ? "/usr/bin/sudo" : smcBinaryPath,
            arguments: usesSudoForSMCWrites
                ? [smcBinaryPath, "-k", key, "-w", hex]
                : ["-k", key, "-w", hex],
            label: "sudo smc -k \(key) -w \(hex)"
        )
        guard !result.combinedOutput.contains("Error:") else {
            throw BatteryError.commandFailed(result.command, result.exitCode, result.combinedOutput)
        }
    }

    // MARK: - CLI execution

    var batteryEnvironment: [String: String] {
        let batteryDirectory = URL(fileURLWithPath: batteryPath).deletingLastPathComponent().path
        return [
            "PATH": "\(batteryDirectory):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName()
        ]
    }

    func ensureSleepPreparationDeadline(_ deadlineUptimeNanoseconds: UInt64?) throws {
        guard let deadlineUptimeNanoseconds else { return }
        guard monotonicNow() < deadlineUptimeNanoseconds else {
            throw BatteryError.commandFailed(
                "prepare battery for system sleep",
                -1,
                "the end-to-end IOKit acknowledgement deadline expired"
            )
        }
    }

    func boundedSleepPreparationTimeout(
        maximum: TimeInterval,
        deadlineUptimeNanoseconds: UInt64?
    ) throws -> TimeInterval {
        guard let deadlineUptimeNanoseconds else { return maximum }
        let now = monotonicNow()
        guard deadlineUptimeNanoseconds > now else {
            try ensureSleepPreparationDeadline(deadlineUptimeNanoseconds)
            return maximum
        }
        let remaining = TimeInterval(deadlineUptimeNanoseconds - now) / 1_000_000_000
        return min(maximum, remaining)
    }

    func batteryCommand(
        _ arguments: [String],
        timeout: TimeInterval = 30,
        outputPolicy: BatteryCommandRunner.OutputPolicy = .capture,
        descendantPolicy: BatteryCommandRunner.DescendantPolicy = .requireProcessGroupExit
    ) async throws -> BatteryCommandResult {
        try revalidateExecutableIdentity(
            path: batteryPath,
            expected: batteryExecutableIdentity,
            displayName: "battery CLI"
        )
        return try await runProcess(
            executable: "/bin/bash",
            arguments: [batteryPath] + arguments,
            environment: batteryEnvironment,
            label: "battery \(arguments.joined(separator: " "))",
            timeout: timeout,
            outputPolicy: outputPolicy,
            descendantPolicy: descendantPolicy
        )
    }

    private func launchLongRunning(_ arguments: [String], label: String) async throws {
        try revalidateExecutableIdentity(
            path: batteryPath,
            expected: batteryExecutableIdentity,
            displayName: "battery CLI"
        )
        _ = try await runner.launchLongRunning(
            BatteryCommandRunner.Command(
                executable: "/bin/bash",
                arguments: [batteryPath] + arguments,
                environment: batteryEnvironment,
                label: label,
                timeout: longRunningOperationTimeout,
                outputPolicy: .discardStdoutCaptureStderr,
                descendantPolicy: .allowPersistentProcessGroup
            )
        )
    }

    func revalidateExecutableIdentity(
        path: String,
        expected: ExecutableIdentity?,
        displayName: String
    ) throws {
        if executableTrustPolicy == .testFixture, expected == nil { return }
        guard let expected else {
            throw BatteryError.preflightFailed("\(displayName) was not validated during initialization")
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw BatteryError.preflightFailed("\(displayName) identity can no longer be verified")
        }
        let observed = executableIdentity(from: metadata)
        guard observed == expected else {
            throw BatteryError.preflightFailed("\(displayName) changed after preflight; restart and verify the installation")
        }
    }

    func executableIdentity(from metadata: stat) -> ExecutableIdentity {
        ExecutableIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            owner: metadata.st_uid,
            group: metadata.st_gid,
            mode: metadata.st_mode,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
            changedSeconds: metadata.st_ctimespec.tv_sec,
            changedNanoseconds: metadata.st_ctimespec.tv_nsec
        )
    }

    private func verifyLongRunningStart(
        command: String,
        statusMatches: (BatteryControlStatus) -> Bool
    ) async throws -> BatteryControlStatus {
        do {
            let now = DispatchTime.now().uptimeNanoseconds
            let deadlineResult = now.addingReportingOverflow(longRunningVerificationTimeoutNanoseconds)
            let deadline = deadlineResult.overflow ? UInt64.max : deadlineResult.partialValue
            var lastVerificationFailure = "status_csv did not confirm the requested operation"

            while true {
                try Task.checkCancellation()
                guard await runner.isLongRunningActive() else {
                    let result = await runner.longRunningResult()
                    let output = result?.combinedOutput ?? ""
                    throw BatteryError.commandFailed(
                        command,
                        result?.exitCode ?? -1,
                        output.isEmpty ? "process exited before the operation was established" : output
                    )
                }

                do {
                    let status = try await readControlStatusUnlocked()
                    if statusMatches(status), await runner.isLongRunningActive() { return status }
                    lastVerificationFailure = "status_csv did not confirm the requested operation"
                } catch {
                    lastVerificationFailure = error.localizedDescription
                }

                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw BatteryError.commandFailed(command, -1, lastVerificationFailure)
                }
                try await Task.sleep(nanoseconds: longRunningVerificationPollNanoseconds)
            }
        } catch {
            let verificationError = error
            do {
                _ = try await runner.cancelLongRunning()
            } catch {
                throw BatteryError.commandFailed(
                    command,
                    -1,
                    "verification failed: \(verificationError.localizedDescription); cleanup failed: \(error.localizedDescription)"
                )
            }
            throw verificationError
        }
    }

    func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        label: String,
        timeout: TimeInterval = 30,
        outputPolicy: BatteryCommandRunner.OutputPolicy = .capture,
        descendantPolicy: BatteryCommandRunner.DescendantPolicy = .requireProcessGroupExit,
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> BatteryCommandResult {
        let result: BatteryCommandResult
        do {
            result = try await runner.run(
                BatteryCommandRunner.Command(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    label: label,
                    timeout: timeout,
                    outputPolicy: outputPolicy,
                    descendantPolicy: descendantPolicy
                )
            )
        } catch is CancellationError {
            throw BatteryError.commandCancelled(label)
        } catch let error as BatteryCommandRunnerError {
            throw BatteryError.commandFailed(label, -1, error.localizedDescription)
        }

        switch result.termination {
        case .cancelled:
            throw BatteryError.commandCancelled(label)
        case .timedOut:
            throw BatteryError.commandTimedOut(label)
        case .uncaughtSignal(let signal):
            throw BatteryError.commandFailed(label, result.exitCode, "terminated by signal \(signal): \(result.combinedOutput)")
        case .exited:
            guard allowedExitCodes.contains(result.exitCode) else {
                throw BatteryError.commandFailed(label, result.exitCode, result.combinedOutput)
            }
            guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
                throw BatteryError.commandFailed(
                    label,
                    result.exitCode,
                    "command output exceeded the capture limit"
                )
            }
            return result
        }
    }

    private func recordVerifiedOperation(
        _ operation: String,
        before: BatteryControlStatus?,
        after: BatteryControlStatus
    ) async {
        await diagnostics.record(
            DiagnosticEvent(
                category: .control,
                operation: operation,
                outcome: .succeeded,
                stateBefore: before?.diagnosticDescription ?? "unavailable",
                stateAfter: after.diagnosticDescription
            )
        )
    }

    private func readPreOperationStatus(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async -> BatteryControlStatus? {
        guard executableTrustPolicy == .production else { return nil }
        return try? await readControlStatusUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
    }

    #if DEBUG
    func runFixtureForTesting(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> BatteryCommandResult {
        try await runner.run(
            BatteryCommandRunner.Command(
                executable: executable,
                arguments: arguments,
                label: "test fixture",
                timeout: timeout
            )
        )
    }
    #endif

    private func validateChargeLevel(_ level: Int) throws {
        guard UserSettings.chargeLimitRange.contains(level) else {
            throw BatteryError.invalidChargeLevel(level)
        }
    }

    func withGate<T>(
        _ gate: AsyncOperationGate,
        operation: () async throws -> T
    ) async throws -> T {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }
}
