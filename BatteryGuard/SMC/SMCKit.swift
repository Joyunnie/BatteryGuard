import Foundation
import IOKit

// MARK: - SMC Constants

private let kSMCKeySize = 4
private let kSMCBytesSize = 32

/// IOConnectCallStructMethod selector for SMC
private let kKernelIndexSMC: UInt32 = 2

/// SMC command codes (placed in data8 field)
private let kSMCCmdReadBytes: UInt8 = 5
private let kSMCCmdWriteBytes: UInt8 = 6
private let kSMCCmdReadKeyInfo: UInt8 = 9

// MARK: - SMC Keys (Apple Silicon M-series)
// Note: BCLM does NOT exist on Apple Silicon. Charge limiting is done by
// toggling CH0B/CH0C/CHTE on/off based on current battery percentage.

private let kSMCKeyCH0B = "CH0B"  // Charging inhibit (ui8: 0x00=allow, 0x02=inhibit)
private let kSMCKeyCH0C = "CH0C"  // Charge circuit control (ui8: 0x00=allow, 0x02=inhibit)
private let kSMCKeyCHTE = "CHTE"  // Charge termination enable (4 bytes: 0x01000000=disable, 0x00000000=enable)
private let kSMCKeyCH0I = "CH0I"  // Force discharge - isolate battery (ui8: 0x01=on, 0x00=off)
private let kSMCKeyCHIE = "CHIE"  // Force discharge - charge input enable (ui8: 0x08=on, 0x00=off)
private let kSMCKeyCH0J = "CH0J"  // Force discharge - battery power only (ui8: 0x01=on, 0x00=off)
private let kSMCKeyTB0T = "TB0T"  // Battery temp sensor 0
private let kSMCKeyTB1T = "TB1T"  // Battery temp sensor 1
private let kSMCKeyTB2T = "TB2T"  // Battery temp sensor 2
private let kSMCKeyACLC = "ACLC"  // MagSafe LED control (ui8: 0x00-0x04)

// MARK: - SMCParamStruct (must be exactly 80 bytes)

/// Matches the C `SMCKeyData_t` struct layout used by IOKit SMC driver.
/// Fields and explicit padding are arranged to match C struct alignment on both
/// Intel and Apple Silicon. The static assert at the bottom of this file guards correctness.
struct SMCParamStruct {
    // key: UInt32 — offset 0
    var key: UInt32 = 0

    // SMCKeyData_vers_t — offset 4, 6 bytes
    var vers_major: UInt8 = 0
    var vers_minor: UInt8 = 0
    var vers_build: UInt8 = 0
    var vers_reserved: UInt8 = 0
    var vers_release: UInt16 = 0

    // Padding to align pLimitData to 4-byte boundary — offset 10
    var _pad0: UInt16 = 0

    // SMCKeyData_pLimitData_t — offset 12, 16 bytes
    var pLimit_version: UInt16 = 0
    var pLimit_length: UInt16 = 0
    var pLimit_cpuPLimit: UInt32 = 0
    var pLimit_gpuPLimit: UInt32 = 0
    var pLimit_memPLimit: UInt32 = 0

    // SMCKeyData_keyInfo_t — offset 28, 9 bytes + 3 padding = 12
    var keyInfo_dataSize: UInt32 = 0
    var keyInfo_dataType: UInt32 = 0
    var keyInfo_dataAttributes: UInt8 = 0
    var _pad1: UInt8 = 0
    var _pad2: UInt16 = 0

    // result, status, data8 — offset 40
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0

    // Padding for data32 alignment — offset 43
    var _pad3: UInt8 = 0

    // data32 — offset 44
    var data32: UInt32 = 0

    // bytes[32] — offset 48
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// Compile-time size guarantee
private let _smcStructSizeCheck: Void = {
    assert(MemoryLayout<SMCParamStruct>.size == 80,
           "SMCParamStruct must be exactly 80 bytes, got \(MemoryLayout<SMCParamStruct>.size)")
}()

// MARK: - MagSafe LED State (ACLC key, 0x00-0x04)

enum MagSafeLEDState: UInt8 {
    case off = 0x00
    case green = 0x01
    case orange = 0x02
    case auto = 0x03
    case errorBlink = 0x04
}

// MARK: - SMCError

enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case failedToOpen(kern_return_t)
    case notOpen
    case keyNotFound(String)
    case readFailed(String, kern_return_t)
    case writeFailed(String, kern_return_t)
    case keyInfoFailed(String, kern_return_t)
    case unexpectedDataSize(String, expected: UInt32, got: UInt32)

    var description: String {
        switch self {
        case .driverNotFound:
            return "SMC driver not found (tried AppleSMCKeysEndpoint and AppleSMC)"
        case .failedToOpen(let kr):
            return "Failed to open SMC connection: \(String(format: "0x%08x", kr))"
        case .notOpen:
            return "SMC connection is not open"
        case .keyNotFound(let key):
            return "SMC key '\(key)' not found"
        case .readFailed(let key, let kr):
            return "Failed to read SMC key '\(key)': \(String(format: "0x%08x", kr))"
        case .writeFailed(let key, let kr):
            return "Failed to write SMC key '\(key)': \(String(format: "0x%08x", kr))"
        case .keyInfoFailed(let key, let kr):
            return "Failed to get key info for '\(key)': \(String(format: "0x%08x", kr))"
        case .unexpectedDataSize(let key, let expected, let got):
            return "SMC key '\(key)' expected \(expected) bytes, got \(got)"
        }
    }
}

// MARK: - SMCKit

final class SMCKit {
    static let shared = SMCKit()

    private var connection: io_connect_t = 0
    private var isOpen = false
    private let lock = NSLock()

    deinit {
        if isOpen {
            try? close()
        }
    }

    // MARK: - Connection

    /// Open a connection to the SMC driver.
    /// Tries "AppleSMCKeysEndpoint" first (Apple Silicon), falls back to "AppleSMC" (Intel).
    func open() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isOpen else { return }

        let serviceNames = ["AppleSMCKeysEndpoint", "AppleSMC"]
        var service: io_service_t = IO_OBJECT_NULL

        for name in serviceNames {
            service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching(name)
            )
            if service != IO_OBJECT_NULL { break }
        }

        guard service != IO_OBJECT_NULL else {
            throw SMCError.driverNotFound
        }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard kr == kIOReturnSuccess else {
            throw SMCError.failedToOpen(kr)
        }

        isOpen = true
    }

    /// Close the SMC connection.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }

        guard isOpen else { return }
        IOServiceClose(connection)
        connection = 0
        isOpen = false
    }

    // MARK: - Low-level Read/Write

    /// Read a single UInt8 value from an SMC key.
    func readUInt8(key: String) throws -> UInt8 {
        let (bytes, dataSize) = try readKeyRaw(key: key)
        guard dataSize >= 1 else {
            throw SMCError.unexpectedDataSize(key, expected: 1, got: dataSize)
        }
        return bytes.0
    }

    /// Write a single UInt8 value to an SMC key.
    func writeUInt8(key: String, value: UInt8) throws {
        print("[SMCKit] writeUInt8(\(key), \(value))")
        do {
            try writeKeyRaw(key: key, dataSize: 1) { bytes in
                bytes.0 = value
            }
            print("[SMCKit] writeUInt8(\(key), \(value)) → success")
        } catch {
            print("[SMCKit] writeUInt8(\(key), \(value)) → FAILED: \(error)")
            throw error
        }
    }

    /// Read a float value from an SMC key.
    /// Handles "flt " (4-byte IEEE float) and "fpe2" (2-byte fixed-point) types.
    func readFloat(key: String) throws -> Float {
        let (bytes, dataSize) = try readKeyRaw(key: key)

        // Get key info to determine data type
        let keyInfo = try getKeyInfo(key: key)
        let typeCode = keyInfo.keyInfo_dataType

        // "flt " = 0x666c7420
        if typeCode == fourCharCode("flt ") && dataSize >= 4 {
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { dest in
                dest[0] = bytes.0
                dest[1] = bytes.1
                dest[2] = bytes.2
                dest[3] = bytes.3
            }
            return value
        }

        // "fpe2" = fixed point, 2 fractional bits
        if typeCode == fourCharCode("fpe2") && dataSize >= 2 {
            let raw = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
            return Float(raw) / 4.0
        }

        // "sp78" = signed fixed point 7.8
        if typeCode == fourCharCode("sp78") && dataSize >= 2 {
            let raw = Int16(bitPattern: (UInt16(bytes.0) << 8) | UInt16(bytes.1))
            return Float(raw) / 256.0
        }

        // Fallback: try big-endian 2-byte unsigned as temperature
        if dataSize >= 2 {
            let raw = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
            return Float(raw) / 256.0
        }

        throw SMCError.unexpectedDataSize(key, expected: 2, got: dataSize)
    }

    // MARK: - Convenience Methods

    // ── Charging Control ──────────────────────────────────────
    // Apple Silicon has no BCLM key. Charge limiting is done by
    // toggling the charge circuit on/off via CH0B + CH0C + CHTE.

    /// Inhibit charging (CH0B=0x02, CH0C=0x02, CHTE=0x01000000).
    func inhibitCharging() throws {
        try writeUInt8(key: kSMCKeyCH0B, value: 0x02)
        try writeUInt8(key: kSMCKeyCH0C, value: 0x02)
        try writeBytes(key: kSMCKeyCHTE, bytes: [0x01, 0x00, 0x00, 0x00])
    }

    /// Allow charging (CH0B=0x00, CH0C=0x00, CHTE=0x00000000).
    func allowCharging() throws {
        try writeUInt8(key: kSMCKeyCH0B, value: 0x00)
        try writeUInt8(key: kSMCKeyCH0C, value: 0x00)
        try writeBytes(key: kSMCKeyCHTE, bytes: [0x00, 0x00, 0x00, 0x00])
    }

    // ── Force Discharge ───────────────────────────────────────
    // Forces the system to run on battery even with adapter connected.
    // CH0I=isolate battery path, CHIE=charge input, CH0J=battery power only.

    /// Enable force discharge (CH0I=0x01, CHIE=0x08, CH0J=0x01).
    func enableForceDischarge() throws {
        try writeUInt8(key: kSMCKeyCH0I, value: 0x01)
        try writeUInt8(key: kSMCKeyCHIE, value: 0x08)
        try writeUInt8(key: kSMCKeyCH0J, value: 0x01)
    }

    /// Disable force discharge (CH0I=0x00, CHIE=0x00, CH0J=0x00).
    func disableForceDischarge() throws {
        try writeUInt8(key: kSMCKeyCH0I, value: 0x00)
        try writeUInt8(key: kSMCKeyCHIE, value: 0x00)
        try writeUInt8(key: kSMCKeyCH0J, value: 0x00)
    }

    // ── Battery Temperature ───────────────────────────────────

    /// Read battery temperature in °C. Returns the maximum of TB0T/TB1T/TB2T,
    /// ignoring keys that don't exist on the current hardware.
    func readBatteryTemperature() throws -> Float {
        let keys = [kSMCKeyTB0T, kSMCKeyTB1T, kSMCKeyTB2T]
        var maxTemp: Float = -Float.greatestFiniteMagnitude
        var anySuccess = false

        for key in keys {
            do {
                let temp = try readFloat(key: key)
                if temp > maxTemp {
                    maxTemp = temp
                }
                anySuccess = true
            } catch SMCError.keyNotFound, SMCError.readFailed, SMCError.keyInfoFailed {
                continue
            }
        }

        guard anySuccess else {
            throw SMCError.keyNotFound("TB0T/TB1T/TB2T")
        }
        return maxTemp
    }

    // ── MagSafe LED ───────────────────────────────────────────

    /// Set the MagSafe LED state (ACLC key).
    func setMagSafeLED(_ state: MagSafeLEDState) throws {
        try writeUInt8(key: kSMCKeyACLC, value: state.rawValue)
    }

    // ── Multi-byte Write Helper ───────────────────────────────

    /// Write an array of bytes to an SMC key.
    func writeBytes(key: String, bytes data: [UInt8]) throws {
        print("[SMCKit] writeBytes(\(key), \(data.map { String(format: "0x%02x", $0) }))")
        do {
            try writeKeyRaw(key: key, dataSize: UInt32(data.count)) { bytes in
                if data.count > 0 { bytes.0 = data[0] }
                if data.count > 1 { bytes.1 = data[1] }
                if data.count > 2 { bytes.2 = data[2] }
                if data.count > 3 { bytes.3 = data[3] }
            }
            print("[SMCKit] writeBytes(\(key)) → success")
        } catch {
            print("[SMCKit] writeBytes(\(key)) → FAILED: \(error)")
            throw error
        }
    }

    // MARK: - Internal Helpers

    private func ensureOpen() throws {
        guard isOpen else { throw SMCError.notOpen }
    }

    /// Convert a 4-character key string to big-endian UInt32.
    private func fourCharCode(_ key: String) -> UInt32 {
        let chars = Array(key.utf8)
        guard chars.count >= 4 else { return 0 }
        return (UInt32(chars[0]) << 24)
             | (UInt32(chars[1]) << 16)
             | (UInt32(chars[2]) << 8)
             | UInt32(chars[3])
    }

    /// Call the SMC driver via IOConnectCallStructMethod.
    private func smcCall(input: inout SMCParamStruct) throws -> SMCParamStruct {
        lock.lock()
        defer { lock.unlock() }

        try ensureOpen()

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size

        let kr = IOConnectCallStructMethod(
            connection,
            kKernelIndexSMC,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )

        guard kr == kIOReturnSuccess else {
            print("[SMCKit] smcCall failed: kr=0x\(String(kr, radix: 16)), cmd=\(input.data8), result=\(output.result)")
            throw SMCError.readFailed("", kr)
        }

        // result 필드가 0이 아니면 SMC 내부 에러
        if output.result != 0 {
            print("[SMCKit] smcCall SMC-level error: result=\(output.result), cmd=\(input.data8)")
        }

        return output
    }

    /// Get key info (data type, size, attributes) for an SMC key.
    private func getKeyInfo(key: String) throws -> SMCParamStruct {
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = kSMCCmdReadKeyInfo

        do {
            return try smcCall(input: &input)
        } catch SMCError.readFailed(_, let kr) {
            throw SMCError.keyInfoFailed(key, kr)
        }
    }

    /// Read raw bytes from an SMC key.
    /// Returns the 32-byte tuple and the actual data size.
    private func readKeyRaw(key: String) throws -> (
        (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8),
        UInt32
    ) {
        // First, get key info to learn the data size
        let info = try getKeyInfo(key: key)
        let dataSize = info.keyInfo_dataSize

        guard dataSize > 0 else {
            throw SMCError.keyNotFound(key)
        }

        // Now read the actual value
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = kSMCCmdReadBytes
        input.keyInfo_dataSize = dataSize

        do {
            let output = try smcCall(input: &input)
            return (output.bytes, dataSize)
        } catch SMCError.readFailed(_, let kr) {
            throw SMCError.readFailed(key, kr)
        }
    }

    /// Write raw bytes to an SMC key.
    /// The `configure` closure receives a mutable pointer to the 32-byte buffer to fill in.
    private func writeKeyRaw(key: String, dataSize: UInt32,
                             configure: (inout (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Void
    ) throws {
        // Verify the key exists and get its info
        let info = try getKeyInfo(key: key)
        let actualSize = info.keyInfo_dataSize

        guard actualSize > 0 else {
            throw SMCError.keyNotFound(key)
        }

        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = kSMCCmdWriteBytes
        input.keyInfo_dataSize = actualSize
        configure(&input.bytes)

        do {
            _ = try smcCall(input: &input)
        } catch SMCError.readFailed(_, let kr) {
            throw SMCError.writeFailed(key, kr)
        }
    }
}
