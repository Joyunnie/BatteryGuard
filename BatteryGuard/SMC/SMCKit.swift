import Foundation

// MARK: - Paths

private let kSMCBinaryPath = "/usr/local/co.palokaj.battery/smc"

// MARK: - MagSafe LED State (ACLC key)

enum MagSafeLEDState: UInt8 {
    case off = 0x00
    case green = 0x03
    case orange = 0x04
    case auto = 0x05
}

// MARK: - SMCError

enum SMCError: Error, CustomStringConvertible {
    case binaryNotFound
    case commandFailed(String, Int32, String)
    case parseFailed(String, String)

    var description: String {
        switch self {
        case .binaryNotFound:
            return "SMC binary not found at \(kSMCBinaryPath)"
        case .commandFailed(let cmd, let code, let output):
            return "Command failed (\(code)): \(cmd) — \(output)"
        case .parseFailed(let key, let raw):
            return "Failed to parse SMC output for '\(key)': \(raw)"
        }
    }
}

// MARK: - SMCKit
/// Direct sudo smc binary calls for all writes. Reads without sudo.
/// M3 confirmed keys: CHTE (charging), CHIE (discharge), ACLC (LED), TB0T (temp).
/// CH0B/CH0C return "no data" on M3 — not used.

final class SMCKit {
    static let shared = SMCKit()

    func open() throws {
        guard FileManager.default.fileExists(atPath: kSMCBinaryPath) else {
            throw SMCError.binaryNotFound
        }
        print("[SMCKit] Using smc binary at \(kSMCBinaryPath)")
    }

    func close() throws {}

    // MARK: - Charging Control (CHTE key, 4 bytes)

    func inhibitCharging() throws {
        try smcWrite(key: "CHTE", hexValue: "01000000")
    }

    func allowCharging() throws {
        try smcWrite(key: "CHTE", hexValue: "00000000")
    }

    // MARK: - Force Discharge (CHIE key)

    func enableForceDischarge() throws {
        try smcWrite(key: "CHIE", hexValue: "08")
    }

    func disableForceDischarge() throws {
        try smcWrite(key: "CHIE", hexValue: "00")
    }

    // MARK: - Battery Temperature (no sudo)

    func readBatteryTemperature() throws -> Float {
        let keys = ["TB0T", "TB1T", "TB2T"]
        var maxTemp: Float = -Float.greatestFiniteMagnitude
        var anySuccess = false

        for key in keys {
            do {
                let temp = try smcReadFloat(key: key)
                if temp > maxTemp { maxTemp = temp }
                anySuccess = true
            } catch {
                continue
            }
        }

        guard anySuccess else {
            throw SMCError.commandFailed("smc temp read", -1, "no temperature sensors found")
        }
        return maxTemp
    }

    // MARK: - MagSafe LED (ACLC key)

    func setMagSafeLED(_ state: MagSafeLEDState) throws {
        try smcWrite(key: "ACLC", hexValue: String(format: "%02x", state.rawValue))
    }

    // MARK: - Low-level Read (no sudo)

    func readUInt8(key: String) throws -> UInt8 {
        let output = try smcRead(key: key)
        if let match = output.range(of: #"\(bytes ([0-9a-fA-F ]+)\)"#, options: .regularExpression) {
            let bytesStr = output[match]
                .replacingOccurrences(of: "(bytes ", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let first = bytesStr.split(separator: " ").first,
               let val = UInt8(first, radix: 16) {
                return val
            }
        }
        if output.contains("no data") { return 0 }
        throw SMCError.parseFailed(key, output)
    }

    func smcReadFloat(key: String) throws -> Float {
        let output = try smcRead(key: key)
        if let bracketEnd = output.range(of: "]"),
           let bytesStart = output.range(of: "(bytes") {
            let valueStr = output[bracketEnd.upperBound..<bytesStart.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let val = Float(valueStr) { return val }
        }
        if output.contains("no data") { return 0 }
        throw SMCError.parseFailed(key, output)
    }

    // MARK: - Subprocess Helpers

    /// Read: smc -k KEY -r (no sudo)
    private func smcRead(key: String) throws -> String {
        let (code, stdout, stderr) = run(kSMCBinaryPath, args: ["-k", key, "-r"])
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || output.contains("Error:") {
            throw SMCError.commandFailed("smc -k \(key) -r", code,
                (stderr.isEmpty ? output : stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    /// Write: sudo smc -k KEY -w VALUE
    private func smcWrite(key: String, hexValue: String) throws {
        print("[SMCKit] write \(key) = \(hexValue)")
        let (code, stdout, stderr) = run("/usr/bin/sudo", args: [kSMCBinaryPath, "-k", key, "-w", hexValue])
        let output = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || output.contains("Error:") {
            print("[SMCKit] write \(key) FAILED: \(output)")
            throw SMCError.commandFailed("sudo smc -k \(key) -w \(hexValue)", code, output)
        }
        print("[SMCKit] write \(key) = \(hexValue) → OK")
    }

    private func run(_ executable: String, args: [String]) -> (Int32, String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        return (
            proc.terminationStatus,
            String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
