import Foundation
import IOKit

// MARK: - Paths

private let kBatteryBinaryPath = "/usr/local/co.palokaj.battery/battery"
private let kSMCBinaryPath = "/usr/local/co.palokaj.battery/smc"

// MARK: - MagSafe LED State (ACLC key values from battery script)

enum MagSafeLEDState: UInt8 {
    case off = 0x00
    case green = 0x03
    case orange = 0x04
    case auto = 0x05   // reset/auto
}

// MARK: - SMCError

enum SMCError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case commandFailed(String, Int32, String)  // command, exit code, output
    case parseFailed(String, String)           // key, raw output

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            return "Binary not found at \(path)"
        case .commandFailed(let cmd, let code, let output):
            return "Command failed (\(code)): \(cmd) — \(output)"
        case .parseFailed(let key, let raw):
            return "Failed to parse SMC output for '\(key)': \(raw)"
        }
    }
}

// MARK: - SMCKit
/// Uses the battery CLI tool for charging control and the smc binary for reads/LED.
/// The battery script handles sudo internally via visudo configuration.

final class SMCKit {
    static let shared = SMCKit()

    // MARK: - Connection

    func open() throws {
        guard FileManager.default.fileExists(atPath: kBatteryBinaryPath) else {
            throw SMCError.binaryNotFound(kBatteryBinaryPath)
        }
        guard FileManager.default.fileExists(atPath: kSMCBinaryPath) else {
            throw SMCError.binaryNotFound(kSMCBinaryPath)
        }
        print("[SMCKit] Using battery CLI at \(kBatteryBinaryPath)")
        print("[SMCKit] Using smc binary at \(kSMCBinaryPath)")
    }

    func close() throws {
        // no-op
    }

    // MARK: - Charging Control (via battery CLI)

    /// Inhibit charging: `battery charging off`
    func inhibitCharging() throws {
        print("[SMCKit] inhibitCharging")
        try runBattery(args: ["charging", "off"])
    }

    /// Allow charging: `battery charging on`
    func allowCharging() throws {
        print("[SMCKit] allowCharging")
        try runBattery(args: ["charging", "on"])
    }

    // MARK: - Force Discharge (via battery CLI)

    /// Enable force discharge: `battery adapter off`
    func enableForceDischarge() throws {
        print("[SMCKit] enableForceDischarge")
        try runBattery(args: ["adapter", "off"])
    }

    /// Disable force discharge: `battery adapter on`
    func disableForceDischarge() throws {
        print("[SMCKit] disableForceDischarge")
        try runBattery(args: ["adapter", "on"])
    }

    // MARK: - Battery Temperature (via smc binary, no sudo needed for reads)

    /// Read battery temperature in °C from TB0T/TB1T/TB2T.
    func readBatteryTemperature() throws -> Float {
        let keys = ["TB0T", "TB1T", "TB2T"]
        var maxTemp: Float = -Float.greatestFiniteMagnitude
        var anySuccess = false

        for key in keys {
            do {
                let temp = try readSMCFloat(key: key)
                if temp > maxTemp { maxTemp = temp }
                anySuccess = true
            } catch {
                continue
            }
        }

        guard anySuccess else {
            throw SMCError.commandFailed("smc -k TB0T -r", -1, "no temperature sensors found")
        }
        return maxTemp
    }

    // MARK: - MagSafe LED (via smc binary with sudo)

    /// Set MagSafe LED state via ACLC key.
    func setMagSafeLED(_ state: MagSafeLEDState) throws {
        let hexValue = String(format: "%02x", state.rawValue)
        print("[SMCKit] setMagSafeLED → ACLC = \(hexValue)")
        let (exitCode, stdout, stderr) = runProcess(
            executable: "/usr/bin/sudo",
            args: [kSMCBinaryPath, "-k", "ACLC", "-w", hexValue]
        )
        let output = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode != 0 || output.contains("Error:") {
            print("[SMCKit] setMagSafeLED FAILED: \(output)")
            throw SMCError.commandFailed("sudo smc -k ACLC -w \(hexValue)", exitCode, output)
        }
    }

    // MARK: - SMC Read (via smc binary, no sudo)

    /// Read a UInt8 from an SMC key.
    func readUInt8(key: String) throws -> UInt8 {
        let output = try readSMCRaw(key: key)
        if let match = output.range(of: #"\(bytes ([0-9a-fA-F ]+)\)"#, options: .regularExpression) {
            let bytesStr = output[match]
                .replacingOccurrences(of: "(bytes ", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces)
            let firstByte = bytesStr.split(separator: " ").first ?? ""
            if let val = UInt8(firstByte, radix: 16) {
                return val
            }
        }
        if output.contains("no data") {
            return 0
        }
        throw SMCError.parseFailed(key, output)
    }

    /// Read a Float from an SMC key (for temperature sensors).
    func readSMCFloat(key: String) throws -> Float {
        let output = try readSMCRaw(key: key)
        // Parse decimal value between "]" and "(bytes"
        // e.g. "  TB0T  [flt ]  25.1 (bytes c8 cc c4 41)"
        if let bracketEnd = output.range(of: "]"),
           let bytesStart = output.range(of: "(bytes") {
            let valueStr = output[bracketEnd.upperBound..<bytesStart.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let val = Float(valueStr) {
                return val
            }
        }
        if output.contains("no data") {
            return 0
        }
        throw SMCError.parseFailed(key, output)
    }

    /// Raw SMC read — returns the full output line.
    private func readSMCRaw(key: String) throws -> String {
        let (exitCode, stdout, stderr) = runProcess(
            executable: kSMCBinaryPath,
            args: ["-k", key, "-r"]
        )
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode != 0 || output.contains("Error:") {
            let errMsg = stderr.isEmpty ? output : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SMCError.commandFailed("smc -k \(key) -r", exitCode, errMsg)
        }
        return output
    }

    // MARK: - Process Helpers

    /// Run the battery CLI with BATTERY_HELPER_MODE=1 to skip maintain daemon interference.
    private func runBattery(args: [String]) throws {
        let (exitCode, stdout, stderr) = runProcess(
            executable: kBatteryBinaryPath,
            args: args,
            environment: ["BATTERY_HELPER_MODE": "1"]
        )
        let cmd = "battery \(args.joined(separator: " "))"
        let output = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)

        if exitCode != 0 {
            print("[SMCKit] \(cmd) FAILED (exit \(exitCode)): \(output)")
            throw SMCError.commandFailed(cmd, exitCode, output)
        }
        print("[SMCKit] \(cmd) → OK")
    }

    /// Run an executable with arguments and optional environment overrides.
    private func runProcess(
        executable: String,
        args: [String],
        environment: [String: String]? = nil
    ) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (k, v) in env { processEnv[k] = v }
            process.environment = processEnv
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
