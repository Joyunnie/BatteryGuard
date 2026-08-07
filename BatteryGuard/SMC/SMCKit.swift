// SMCKit.swift
// Semantic battery operations layered over BatteryCommandRunner.

import Foundation
import Darwin

private let defaultBatteryPath = "/usr/local/co.palokaj.battery/battery"
private let defaultSMCBinaryPath = "/usr/local/co.palokaj.battery/smc"

private actor AsyncOperationGate {
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
    func startDischarge(to level: Int) async throws
    func startTopUp(to level: Int) async throws
    func isLongRunningOperationActive() async -> Bool
    func longRunningOperationResult() async -> BatteryCommandResult?
    func cancelLongRunningOperation() async throws
    func requestCancellation() async throws
}

protocol BatteryTemperatureBackend: AnyObject, Sendable {
    func readBatteryTemperature() async throws -> Float
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

    enum ExecutableTrustPolicy: Sendable, Equatable {
        case production
        case testFixture
    }

    static let shared = SMCKit(
        runner: BatteryCommandRunner(diagnostics: .shared),
        diagnostics: .shared
    )

    private let runner: BatteryCommandRunner
    private let controlGate = AsyncOperationGate()
    private let ledGate = AsyncOperationGate()
    private let batteryPath: String
    private let smcBinaryPath: String
    private let usesSudoForSMCWrites: Bool
    private let maintainPIDFilePath: String
    private let maintainWorkerProbe: MaintainWorkerProbe?
    private let executableTrustPolicy: ExecutableTrustPolicy
    private let diagnostics: DiagnosticLog
    private let statusCommandTimeout: TimeInterval = 2
    private let longRunningVerificationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private let longRunningVerificationPollNanoseconds: UInt64 = 100_000_000
    private let longRunningOperationTimeout: TimeInterval = 12 * 60 * 60
    private var rawSMCAvailable = false
    private var savedMagSafeLEDValue: UInt8?
    private var batteryExecutableIdentity: ExecutableIdentity?
    private var smcExecutableIdentity: ExecutableIdentity?

    private struct ExecutableIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private struct MaintainWorkerProcess: Equatable, Sendable {
        let pid: Int32
        let command: String
        let target: Int?
        let identity: ProcessIdentity?
    }

    private struct ProcessIdentity: Equatable, Sendable {
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct ParsedMaintainCommand: Equatable, Sendable {
        let target: Int?
    }

    init(
        runner: BatteryCommandRunner = BatteryCommandRunner(),
        batteryPath: String = defaultBatteryPath,
        smcBinaryPath: String = defaultSMCBinaryPath,
        usesSudoForSMCWrites: Bool = true,
        maintainPIDFilePath: String? = nil,
        maintainWorkerProbe: MaintainWorkerProbe? = nil,
        executableTrustPolicy: ExecutableTrustPolicy = .production,
        diagnostics: DiagnosticLog = .disabled
    ) {
        self.runner = runner
        self.batteryPath = batteryPath
        self.smcBinaryPath = smcBinaryPath
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
        self.diagnostics = diagnostics
    }

    func open() async throws {
        try await withGate(controlGate) {
            try await openUnlocked()
        }
    }

    private func openUnlocked() async throws {
        batteryExecutableIdentity = try validateExecutableBeforeUse(
            path: batteryPath,
            expectedProductionPath: defaultBatteryPath,
            displayName: "battery CLI"
        )
        smcExecutableIdentity = try validateExecutableBeforeUse(
            path: smcBinaryPath,
            expectedProductionPath: defaultSMCBinaryPath,
            displayName: "SMC binary"
        )
        rawSMCAvailable = true

        try await validateBatteryCLIVersionUnlocked()
        _ = try await readControlStatusUnlocked()
        print("[SMCKit] battery CLI and SMC binary ready")
    }

    private func validateExecutableBeforeUse(
        path: String,
        expectedProductionPath: String,
        displayName: String
    ) throws -> ExecutableIdentity {
        guard path.hasPrefix("/") else {
            throw BatteryError.preflightFailed("\(displayName) path is not absolute: \(path)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BatteryError.binaryNotFound(
                "\(displayName) is not installed at \(path). Install and verify it manually before enabling charge control."
            )
        }

        switch executableTrustPolicy {
        case .production:
            guard path == expectedProductionPath else {
                throw BatteryError.preflightFailed(
                    "\(displayName) must use the pinned path \(expectedProductionPath), received \(path)"
                )
            }
            try validateRootOwnedPath(path, expectedType: S_IFREG, displayName: displayName)
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try validateRootOwnedPath(parent, expectedType: S_IFDIR, displayName: "\(displayName) directory")
        case .testFixture:
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & S_IXUSR != 0 else {
                throw BatteryError.preflightFailed("test fixture is not an executable regular file: \(path)")
            }
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw BatteryError.preflightFailed("could not capture \(displayName) identity")
        }
        return ExecutableIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
        )
    }

    private func validateRootOwnedPath(
        _ path: String,
        expectedType: mode_t,
        displayName: String
    ) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw BatteryError.preflightFailed("could not inspect \(displayName) at \(path): \(String(cString: strerror(errno)))")
        }
        guard metadata.st_mode & S_IFMT == expectedType else {
            throw BatteryError.preflightFailed("\(displayName) must not be a symlink and has the wrong file type: \(path)")
        }
        guard metadata.st_uid == 0, metadata.st_gid == 0 else {
            throw BatteryError.preflightFailed("\(displayName) must be owned by root:wheel: \(path)")
        }
        guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw BatteryError.preflightFailed("\(displayName) is writable by group or others: \(path)")
        }
        if expectedType == S_IFREG, metadata.st_mode & S_IXUSR == 0 {
            throw BatteryError.preflightFailed("\(displayName) is not owner-executable: \(path)")
        }
    }

    private func validateBatteryCLIVersionUnlocked() async throws {
        guard executableTrustPolicy == .production else { return }
        let result = try await runProcess(
            executable: "/bin/bash",
            arguments: [batteryPath, "version"],
            environment: batteryEnvironment,
            label: "battery version",
            timeout: statusCommandTimeout
        )
        guard let version = Self.parseSemanticVersion(result.stdout),
              version == [1, 3, 4] else {
            throw BatteryError.preflightFailed(
                "Only the verified battery CLI v1.3.4 contract is supported; received \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    private static func parseSemanticVersion(_ output: String) -> [Int]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionText = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let fields = versionText.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let components = fields.compactMap { Int($0) }
        return components.count == fields.count ? components : nil
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
                let status = try await readControlStatusUnlocked(
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
                guard status.isVerifiedChargingDisabled else {
                    throw BatteryError.commandFailed(
                        "prepare battery for system sleep",
                        -1,
                        "status_csv did not confirm fully disabled control: \(status.diagnosticDescription)"
                    )
                }
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

    // MARK: - Status

    func readControlStatus() async throws -> BatteryControlStatus {
        try await withGate(controlGate) {
            try await readControlStatusUnlocked()
        }
    }

    private func readControlStatusUnlocked(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws -> BatteryControlStatus {
        let result = try await batteryCommand(
            ["status_csv"],
            timeout: try boundedSleepPreparationTimeout(
                maximum: statusCommandTimeout,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
        )
        guard let parsedStatus = Self.parseControlStatus(csv: result.stdout) else {
            throw BatteryError.unsupported("Installed battery CLI returned an unsupported status_csv format")
        }
        let workerStatus = try await readMaintainWorkerStatusUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        return BatteryControlStatus(
            charging: parsedStatus.charging,
            isDischarging: parsedStatus.isDischarging,
            maintainLevel: parsedStatus.maintainLevel,
            maintainWorker: workerStatus
        )
    }

    private func readMaintainWorkerStatusUnlocked(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws -> MaintainWorkerStatus {
        if let maintainWorkerProbe {
            return try await maintainWorkerProbe(maintainPIDFilePath, batteryPath)
        }

        return Self.classifyMaintainWorkers(
            pidFilePID: try readMaintainPIDFile(),
            workers: try await currentMaintainWorkersUnlocked(
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
        )
    }

    static func classifyMaintainWorkers(
        pidFilePID: Int32?,
        processTable: String,
        batteryPath: String
    ) -> MaintainWorkerStatus {
        let workers = parseMaintainWorkerProcesses(processTable: processTable, batteryPath: batteryPath)
        return classifyMaintainWorkers(pidFilePID: pidFilePID, workers: workers)
    }

    private static func classifyMaintainWorkers(
        pidFilePID: Int32?,
        workers: [MaintainWorkerProcess]
    ) -> MaintainWorkerStatus {
        guard workers.count <= 1 else { return .duplicate(pids: workers.map(\.pid).sorted()) }
        guard let worker = workers.first else {
            return pidFilePID == nil ? .stopped : .stale(pid: pidFilePID)
        }
        guard worker.pid == pidFilePID else { return .stale(pid: pidFilePID ?? worker.pid) }
        return .running(pid: worker.pid, target: worker.target)
    }

    private static func parseMaintainWorkerProcesses(
        processTable: String,
        batteryPath: String
    ) -> [MaintainWorkerProcess] {
        processTable.split(whereSeparator: \Character.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  pid > 1,
                  let parsed = Self.parseExactMaintainCommand(
                    String(fields[2]),
                    batteryPath: batteryPath
                  ) else {
                return nil
            }
            return MaintainWorkerProcess(
                pid: pid,
                command: String(fields[2]),
                target: parsed.target,
                identity: nil
            )
        }
    }

    private static func parseExactMaintainCommand(
        _ command: String,
        batteryPath: String
    ) -> ParsedMaintainCommand? {
        let arguments = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let batteryIndex: Int
        if arguments.first == batteryPath {
            batteryIndex = 0
        } else if arguments.count >= 2,
                  ["/bin/bash", "/bin/zsh"].contains(arguments[0]),
                  arguments[1] == batteryPath {
            batteryIndex = 1
        } else {
            return nil
        }
        guard arguments.count == batteryIndex + 3 else { return nil }
        let action = arguments[batteryIndex + 1]
        let targetText = arguments[batteryIndex + 2]
        switch action {
        case "maintain_synchronous":
            guard let target = Int(targetText), UserSettings.chargeLimitRange.contains(target) else {
                return nil
            }
            return ParsedMaintainCommand(target: target)
        case "maintain_voltage_synchronous":
            guard Double(targetText) != nil else { return nil }
            return ParsedMaintainCommand(target: nil)
        default:
            return nil
        }
    }

    private func terminateMaintainWorkersUnlocked(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws {
        let workers = try await currentMaintainWorkersUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        guard !workers.isEmpty else {
            if try readMaintainPIDFile() != nil {
                try FileManager.default.removeItem(atPath: maintainPIDFilePath)
            }
            return
        }

        for worker in workers {
            guard try await isExactCurrentMaintainWorker(
                worker,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ) else { continue }
            guard Darwin.kill(worker.pid, SIGTERM) == 0 || errno == ESRCH else {
                throw BatteryError.commandFailed(
                    "stop maintain worker \(worker.pid)",
                    -1,
                    String(cString: strerror(errno))
                )
            }
        }
        try ensureSleepPreparationDeadline(deadlineUptimeNanoseconds)
        try await Task.sleep(nanoseconds: 250_000_000)
        let remainingAfterTerm = try await currentMaintainWorkersUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        for worker in remainingAfterTerm where workers.contains(worker) {
            guard try await isExactCurrentMaintainWorker(
                worker,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ) else { continue }
            guard Darwin.kill(worker.pid, SIGKILL) == 0 || errno == ESRCH else {
                throw BatteryError.commandFailed(
                    "stop maintain worker \(worker.pid)",
                    -1,
                    String(cString: strerror(errno))
                )
            }
        }
        try ensureSleepPreparationDeadline(deadlineUptimeNanoseconds)
        try await Task.sleep(nanoseconds: 100_000_000)
        let currentWorkers = try await currentMaintainWorkersUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        let survivors = currentWorkers.filter { current in
            workers.contains(current)
        }
        guard survivors.isEmpty else {
            throw BatteryError.commandFailed(
                "stop maintain workers",
                -1,
                "workers survived termination: \(survivors.map(\.pid))"
            )
        }
        if try readMaintainPIDFile() != nil {
            try FileManager.default.removeItem(atPath: maintainPIDFilePath)
        }
    }

    private func isExactCurrentMaintainWorker(
        _ expected: MaintainWorkerProcess,
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> Bool {
        let current = try await currentMaintainWorkersUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        guard current.contains(expected) else { return false }
        return try currentIdentity(for: expected.pid) == expected.identity
    }

    private func currentMaintainWorkersUnlocked(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws -> [MaintainWorkerProcess] {
        let escapedPath = NSRegularExpression.escapedPattern(for: batteryPath)
        let candidates = try await runProcess(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", escapedPath],
            label: "locate battery CLI processes",
            timeout: try boundedSleepPreparationTimeout(
                maximum: statusCommandTimeout,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ),
            allowedExitCodes: [0, 1]
        )
        guard candidates.exitCode == 0 else { return [] }

        let candidatePIDs = candidates.stdout
            .split(whereSeparator: \Character.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 1 && $0 != getpid() }
        guard candidatePIDs.count <= 32 else {
            throw BatteryError.commandFailed(
                "inspect battery CLI processes",
                -1,
                "refusing unbounded process inspection: \(candidatePIDs.count) candidates"
            )
        }
        guard !candidatePIDs.isEmpty else { return [] }

        let inspection = try await runProcess(
            executable: "/bin/ps",
            arguments: [
                "-p",
                candidatePIDs.map(String.init).joined(separator: ","),
                "-o",
                "pid=,pgid=,command="
            ],
            label: "inspect battery CLI processes",
            timeout: try boundedSleepPreparationTimeout(
                maximum: statusCommandTimeout,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ),
            allowedExitCodes: [0, 1]
        )
        guard inspection.exitCode == 0 else { return [] }
        return try Self.parseMaintainWorkerProcesses(
            processTable: inspection.stdout,
            batteryPath: batteryPath
        ).compactMap { worker in
            guard let identity = try currentIdentity(for: worker.pid) else { return nil }
            return MaintainWorkerProcess(
                pid: worker.pid,
                command: worker.command,
                target: worker.target,
                identity: identity
            )
        }
    }

    private func currentIdentity(for pid: Int32) throws -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        errno = 0
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        if result == expectedSize {
            return ProcessIdentity(
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
        }
        if result == 0 {
            let inspectionErrno = errno
            if inspectionErrno == ESRCH { return nil }
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return nil }
            errno = inspectionErrno
        }
        throw BatteryError.commandFailed(
            "inspect maintain worker identity \(pid)",
            -1,
            result == 0 ? String(cString: strerror(errno)) : "incomplete process identity"
        )
    }

    private func readMaintainPIDFile() throws -> Int32? {
        var fileStatus = stat()
        guard Darwin.lstat(maintainPIDFilePath, &fileStatus) == 0 else {
            if errno == ENOENT { return nil }
            throw BatteryError.commandFailed(
                "inspect maintain PID file",
                -1,
                String(cString: strerror(errno))
            )
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_size > 0,
              fileStatus.st_size <= 32 else {
            throw BatteryError.preflightFailed(
                "maintain PID file is not a small current-user-owned regular file"
            )
        }

        let descriptor = Darwin.open(
            maintainPIDFilePath,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BatteryError.commandFailed(
                "open maintain PID file",
                -1,
                String(cString: strerror(errno))
            )
        }
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 33)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, 32)
        }
        guard count > 0 else {
            let message = count == 0 ? "empty file" : String(cString: strerror(errno))
            throw BatteryError.commandFailed("read maintain PID file", -1, message)
        }
        let text = String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(text), pid > 1 else {
            throw BatteryError.preflightFailed("maintain PID file contains an invalid PID")
        }
        return pid
    }

    static func parseControlStatus(csv: String) -> BatteryControlStatus? {
        let line = csv
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 5 else { return nil }

        let charging: BatteryChargingStatus
        switch fields[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enabled": charging = .enabled
        case "disabled": charging = .disabled
        default: charging = .unknown
        }

        let dischargeText = fields[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDischarging: Bool?
        switch dischargeText {
        case "discharging": isDischarging = true
        case "not discharging": isDischarging = false
        default: isDischarging = nil
        }

        return BatteryControlStatus(
            charging: charging,
            isDischarging: isDischarging,
            maintainLevel: Int(fields[4].trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    static func parseChargingStatus(csv: String) -> BatteryChargingStatus {
        parseControlStatus(csv: csv)?.charging ?? .unknown
    }

    // MARK: - Battery temperature

    func readBatteryTemperature() async throws -> Float {
        guard rawSMCAvailable else {
            throw BatteryError.unsupported("Raw SMC binary is unavailable; battery temperature cannot be read")
        }
        try revalidateExecutableIdentity(
            path: smcBinaryPath,
            expected: smcExecutableIdentity,
            displayName: "SMC binary"
        )

        var maximum = -Float.greatestFiniteMagnitude
        var foundValue = false
        var lastReadError: Error?
        for key in ["TB0T", "TB1T", "TB2T"] {
            do {
                let result = try await runProcess(
                    executable: smcBinaryPath,
                    arguments: ["-k", key, "-r"],
                    label: "smc -k \(key) -r"
                )
                for line in result.stdout.components(separatedBy: "\n") where !line.isEmpty {
                    if let bracketEnd = line.range(of: "]"),
                       let bytesStart = line.range(of: "(bytes") {
                        let text = line[bracketEnd.upperBound..<bytesStart.lowerBound]
                            .trimmingCharacters(in: .whitespaces)
                        if let rawValue = Float(text),
                           let value = BatteryMonitor.validatedTemperature(Double(rawValue)) {
                            maximum = max(maximum, Float(value))
                            foundValue = true
                        }
                    }
                }
            } catch {
                lastReadError = error
            }
        }

        guard foundValue else {
            throw lastReadError
                ?? BatteryError.commandFailed("smc temperature read", -1, "no temperature sensors found")
        }
        return maximum
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

    private var batteryEnvironment: [String: String] {
        let batteryDirectory = URL(fileURLWithPath: batteryPath).deletingLastPathComponent().path
        return [
            "PATH": "\(batteryDirectory):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName()
        ]
    }

    private func ensureSleepPreparationDeadline(_ deadlineUptimeNanoseconds: UInt64?) throws {
        guard let deadlineUptimeNanoseconds else { return }
        guard DispatchTime.now().uptimeNanoseconds < deadlineUptimeNanoseconds else {
            throw BatteryError.commandFailed(
                "prepare battery for system sleep",
                -1,
                "the end-to-end IOKit acknowledgement deadline expired"
            )
        }
    }

    private func boundedSleepPreparationTimeout(
        maximum: TimeInterval,
        deadlineUptimeNanoseconds: UInt64?
    ) throws -> TimeInterval {
        guard let deadlineUptimeNanoseconds else { return maximum }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNanoseconds > now else {
            try ensureSleepPreparationDeadline(deadlineUptimeNanoseconds)
            return maximum
        }
        let remaining = TimeInterval(deadlineUptimeNanoseconds - now) / 1_000_000_000
        return min(maximum, remaining)
    }

    private func batteryCommand(
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

    private func revalidateExecutableIdentity(
        path: String,
        expected: ExecutableIdentity?,
        displayName: String
    ) throws {
        guard executableTrustPolicy == .production else { return }
        guard let expected else {
            throw BatteryError.preflightFailed("\(displayName) was not validated during initialization")
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw BatteryError.preflightFailed("\(displayName) identity can no longer be verified")
        }
        let observed = ExecutableIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
        )
        guard observed == expected else {
            throw BatteryError.preflightFailed("\(displayName) changed after preflight; restart and verify the installation")
        }
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

    private func runProcess(
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

    private func withGate<T>(
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
