// SMCKit.swift
// Semantic battery operations layered over BatteryCommandRunner.

import Foundation

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

enum MagSafeLEDState: UInt8, Sendable {
    case green = 0x03
    case orange = 0x04
}

enum BatteryError: Error, LocalizedError, CustomStringConvertible {
    case binaryNotFound(String)
    case invalidChargeLevel(Int)
    case unsupported(String)
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

struct BatteryControlStatus: Equatable, Sendable {
    let charging: BatteryChargingStatus
    let isDischarging: Bool?
    let maintainLevel: Int?
}

/// Hardware-facing seam. Production delegates all child processes to
/// BatteryCommandRunner; tests provide an async fake.
protocol ChargeBackend: AnyObject, Sendable {
    func open() async throws
    func readControlStatus() async throws -> BatteryControlStatus
    func applyMaintain(level: Int) async throws
    func disableCharging() async throws
    func startDischarge(to level: Int) async throws
    func startTopUp(to level: Int) async throws
    func isLongRunningOperationActive() async -> Bool
    func longRunningOperationResult() async -> BatteryCommandResult?
    func cancelLongRunningOperation() async throws
    func requestCancellation() async throws

    func readBatteryTemperature() async throws -> Float
    func setMagSafeLED(_ state: MagSafeLEDState) async throws
    func restoreMagSafeLED() async throws
}

actor SMCKit: ChargeBackend {
    static let shared = SMCKit()

    private let runner: BatteryCommandRunner
    private let controlGate = AsyncOperationGate()
    private let ledGate = AsyncOperationGate()
    private let batteryPath: String
    private let smcBinaryPath: String
    private let usesSudoForSMCWrites: Bool
    private let statusCommandTimeout: TimeInterval = 2
    private let longRunningVerificationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private let longRunningVerificationPollNanoseconds: UInt64 = 100_000_000
    private var rawSMCAvailable = false
    private var savedMagSafeLEDValue: UInt8?

    init(
        runner: BatteryCommandRunner = BatteryCommandRunner(),
        batteryPath: String = defaultBatteryPath,
        smcBinaryPath: String = defaultSMCBinaryPath,
        usesSudoForSMCWrites: Bool = true
    ) {
        self.runner = runner
        self.batteryPath = batteryPath
        self.smcBinaryPath = smcBinaryPath
        self.usesSudoForSMCWrites = usesSudoForSMCWrites
    }

    func open() async throws {
        try await withGate(controlGate) {
            try await openUnlocked()
        }
    }

    private func openUnlocked() async throws {
        guard FileManager.default.fileExists(atPath: batteryPath) else {
            throw BatteryError.binaryNotFound(
                "battery CLI is not installed at \(batteryPath). Install and verify it manually before enabling charge control."
            )
        }

        _ = try await readControlStatusUnlocked()

        let available = FileManager.default.fileExists(atPath: smcBinaryPath)
        rawSMCAvailable = available
        print("[SMCKit] battery CLI ready; raw SMC \(available ? "available" : "unavailable")")
    }

    // MARK: - Verified charge operations

    func applyMaintain(level: Int) async throws {
        try await withGate(controlGate) {
            try await applyMaintainUnlocked(level: level)
        }
    }

    private func applyMaintainUnlocked(level: Int) async throws {
        try validateChargeLevel(level)
        _ = try await batteryCommand(
            ["maintain", "\(level)"],
            outputPolicy: .discardStdoutCaptureStderr
        )

        let status = try await readControlStatusUnlocked()
        guard status.maintainLevel == level else {
            throw BatteryError.commandFailed(
                "battery maintain \(level)",
                -1,
                "status_csv reported maintain=\(status.maintainLevel.map(String.init) ?? "unknown")"
            )
        }
    }

    func disableCharging() async throws {
        try await withGate(controlGate) {
            try await disableChargingUnlocked()
        }
    }

    private func disableChargingUnlocked() async throws {
        _ = try await batteryCommand(["charging", "off"])
        let status = try await readControlStatusUnlocked()
        guard status.charging == .disabled else {
            throw BatteryError.commandFailed(
                "battery charging off",
                -1,
                "status_csv did not confirm disabled charging"
            )
        }
    }

    func startDischarge(to level: Int) async throws {
        try await withGate(controlGate) {
            try validateChargeLevel(level)
            let label = "battery discharge \(level)"
            try await launchLongRunning(["discharge", "\(level)"], label: label)
            try await verifyLongRunningStart(command: label) { $0.isDischarging == true }
        }
    }

    func startTopUp(to level: Int) async throws {
        try await withGate(controlGate) {
            try validateChargeLevel(level)
            let label = "battery charge \(level)"
            try await launchLongRunning(["charge", "\(level)"], label: label)
            try await verifyLongRunningStart(command: label) { $0.charging == .enabled }
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

    private func readControlStatusUnlocked() async throws -> BatteryControlStatus {
        let result = try await batteryCommand(["status_csv"], timeout: statusCommandTimeout)
        guard let status = Self.parseControlStatus(csv: result.stdout) else {
            throw BatteryError.unsupported("Installed battery CLI returned an unsupported status_csv format")
        }
        return status
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
                        if let value = Float(text) {
                            maximum = max(maximum, value)
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
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(batteryDirectory)",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName()
        ]
    }

    private func batteryCommand(
        _ arguments: [String],
        timeout: TimeInterval = 30,
        outputPolicy: BatteryCommandRunner.OutputPolicy = .capture
    ) async throws -> BatteryCommandResult {
        try await runProcess(
            executable: "/bin/bash",
            arguments: [batteryPath] + arguments,
            environment: batteryEnvironment,
            label: "battery \(arguments.joined(separator: " "))",
            timeout: timeout,
            outputPolicy: outputPolicy
        )
    }

    private func launchLongRunning(_ arguments: [String], label: String) async throws {
        _ = try await runner.launchLongRunning(
            BatteryCommandRunner.Command(
                executable: "/bin/bash",
                arguments: [batteryPath] + arguments,
                environment: batteryEnvironment,
                label: label
            )
        )
    }

    private func verifyLongRunningStart(
        command: String,
        statusMatches: (BatteryControlStatus) -> Bool
    ) async throws {
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
                    if statusMatches(status), await runner.isLongRunningActive() { return }
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
        outputPolicy: BatteryCommandRunner.OutputPolicy = .capture
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
                    outputPolicy: outputPolicy
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
            guard result.exitCode == 0 else {
                throw BatteryError.commandFailed(label, result.exitCode, result.combinedOutput)
            }
            return result
        }
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
