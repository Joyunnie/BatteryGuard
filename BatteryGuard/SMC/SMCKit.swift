import Foundation

// MARK: - SMC Binary Path

private let kSMCBinaryPath = "/usr/local/co.palokaj.battery/smc"

// MARK: - SMC Keys (Apple Silicon M-series)

private let kSMCKeyCH0B = "CH0B"  // Charging inhibit (ui8: 0x00=allow, 0x02=inhibit)
private let kSMCKeyCH0C = "CH0C"  // Charge circuit control (ui8: 0x00=allow, 0x02=inhibit)
private let kSMCKeyCHTE = "CHTE"  // Charge termination (ui32: 0x01000000=disable, 0x00000000=enable)
private let kSMCKeyCH0I = "CH0I"  // Force discharge - isolate (ui8: 0x01=on, 0x00=off)
private let kSMCKeyCHIE = "CHIE"  // Force discharge - charge input (ui8: 0x08=on, 0x00=off)
private let kSMCKeyCH0J = "CH0J"  // Force discharge - battery only (ui8: 0x01=on, 0x00=off)
private let kSMCKeyTB0T = "TB0T"  // Battery temp sensor 0
private let kSMCKeyTB1T = "TB1T"  // Battery temp sensor 1
private let kSMCKeyTB2T = "TB2T"  // Battery temp sensor 2
private let kSMCKeyACLC = "ACLC"  // MagSafe LED control (ui8: 0x00-0x04)

// MARK: - MagSafe LED State (ACLC key)

enum MagSafeLEDState: UInt8 {
    case off = 0x00
    case green = 0x01
    case orange = 0x02
    case auto = 0x03
    case errorBlink = 0x04
}

// MARK: - SMCError

enum SMCError: Error, CustomStringConvertible {
    case binaryNotFound
    case readFailed(String, String)   // key, stderr/output
    case writeFailed(String, String)  // key, stderr/output
    case parseFailed(String, String)  // key, raw output

    var description: String {
        switch self {
        case .binaryNotFound:
            return "SMC binary not found at \(kSMCBinaryPath)"
        case .readFailed(let key, let msg):
            return "Failed to read SMC key '\(key)': \(msg)"
        case .writeFailed(let key, let msg):
            return "Failed to write SMC key '\(key)': \(msg)"
        case .parseFailed(let key, let raw):
            return "Failed to parse SMC output for '\(key)': \(raw)"
        }
    }
}

// MARK: - SMCKit (subprocess-based)
/// Uses the battery tool's smc binary for all SMC reads/writes.
/// This avoids SMCParamStruct alignment issues entirely.

final class SMCKit {
    static let shared = SMCKit()

    // MARK: - Connection (no-op for binary approach, kept for API compat)

    func open() throws {
        guard FileManager.default.fileExists(atPath: kSMCBinaryPath) else {
            throw SMCError.binaryNotFound
        }
        print("[SMCKit] Using smc binary at \(kSMCBinaryPath)")
    }

    func close() throws {
        // no-op
    }

    // MARK: - Low-level Read/Write via subprocess

    /// Read an SMC key. Returns raw output line like "  CH0B  [ui8 ]  2 (bytes 02)"
    private func smcRead(key: String) throws -> String {
        let (exitCode, stdout, stderr) = runSMC(args: ["-k", key, "-r"])
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if exitCode != 0 || output.contains("Error:") {
            let errMsg = stderr.isEmpty ? output : stderr
            throw SMCError.readFailed(key, errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }

    /// Write an SMC key with hex value string (e.g. "02", "01000000").
    private func smcWrite(key: String, hexValue: String) throws {
        print("[SMCKit] write \(key) = \(hexValue)")
        let (exitCode, stdout, stderr) = runSMC(args: ["-k", key, "-w", hexValue])
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        if exitCode != 0 || output.contains("Error:") {
            let errMsg = stderr.isEmpty ? output : stderr
            print("[SMCKit] write \(key) FAILED: \(errMsg)")
            throw SMCError.writeFailed(key, errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        print("[SMCKit] write \(key) = \(hexValue) → OK")
    }

    /// Run the smc binary and capture output.
    private func runSMC(args: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kSMCBinaryPath)
        process.arguments = args

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

    // MARK: - Parsing

    /// Parse a UInt8 value from smc output like "  KEY  [ui8 ]  4 (bytes 04)"
    func readUInt8(key: String) throws -> UInt8 {
        let output = try smcRead(key: key)
        // Try parsing "(bytes XX)" first
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
        // "no data" means 0
        if output.contains("no data") {
            return 0
        }
        throw SMCError.parseFailed(key, output)
    }

    /// Parse a Float from smc output for temperature keys.
    /// Output like "  TB0T  [flt ]  25 (bytes c8 cc c4 41)"
    func readFloat(key: String) throws -> Float {
        let output = try smcRead(key: key)
        // Parse the decimal value between "]" and "(bytes"
        // e.g. "  TB0T  [flt ]  25.1 (bytes ...)"
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

    // MARK: - Charging Control

    /// Inhibit charging: CH0B=0x02, CH0C=0x02, CHTE=0x01000000
    func inhibitCharging() throws {
        try smcWrite(key: kSMCKeyCH0B, hexValue: "02")
        try smcWrite(key: kSMCKeyCH0C, hexValue: "02")
        try smcWrite(key: kSMCKeyCHTE, hexValue: "01000000")
    }

    /// Allow charging: CH0B=0x00, CH0C=0x00, CHTE=0x00000000
    func allowCharging() throws {
        try smcWrite(key: kSMCKeyCH0B, hexValue: "00")
        try smcWrite(key: kSMCKeyCH0C, hexValue: "00")
        try smcWrite(key: kSMCKeyCHTE, hexValue: "00000000")
    }

    // MARK: - Force Discharge

    /// Enable force discharge: CH0I=0x01, CHIE=0x08, CH0J=0x01
    func enableForceDischarge() throws {
        try smcWrite(key: kSMCKeyCH0I, hexValue: "01")
        try smcWrite(key: kSMCKeyCHIE, hexValue: "08")
        try smcWrite(key: kSMCKeyCH0J, hexValue: "01")
    }

    /// Disable force discharge: CH0I=0x00, CHIE=0x00, CH0J=0x00
    func disableForceDischarge() throws {
        try smcWrite(key: kSMCKeyCH0I, hexValue: "00")
        try smcWrite(key: kSMCKeyCHIE, hexValue: "00")
        try smcWrite(key: kSMCKeyCH0J, hexValue: "00")
    }

    // MARK: - Battery Temperature

    /// Read battery temperature in °C from TB0T/TB1T/TB2T.
    func readBatteryTemperature() throws -> Float {
        let keys = [kSMCKeyTB0T, kSMCKeyTB1T, kSMCKeyTB2T]
        var maxTemp: Float = -Float.greatestFiniteMagnitude
        var anySuccess = false

        for key in keys {
            do {
                let temp = try readFloat(key: key)
                if temp > maxTemp { maxTemp = temp }
                anySuccess = true
            } catch {
                continue
            }
        }

        guard anySuccess else {
            throw SMCError.readFailed("TB0T/TB1T/TB2T", "no temperature sensors found")
        }
        return maxTemp
    }

    // MARK: - MagSafe LED

    /// Set MagSafe LED state via ACLC key.
    func setMagSafeLED(_ state: MagSafeLEDState) throws {
        try smcWrite(key: kSMCKeyACLC, hexValue: String(format: "%02x", state.rawValue))
    }
}
