/// SMCTest — Manual test program for SMCKit.
/// Run with root privileges: sudo swift SMCTest.swift
/// This is NOT an automated test — it requires a real Mac with SMC hardware.

import Foundation

@main
struct SMCTest {
    static func main() {
        print("=== SMCKit Manual Test ===\n")

        // 1. Verify struct size
        let structSize = MemoryLayout<SMCParamStruct>.size
        print("SMCParamStruct size: \(structSize) bytes")
        guard structSize == 80 else {
            print("FAIL: SMCParamStruct must be exactly 80 bytes, got \(structSize)")
            exit(1)
        }
        print("✓ Struct size is correct (80 bytes)\n")

        // 2. Open SMC connection
        let smc = SMCKit()
        do {
            try smc.open()
            print("✓ SMC connection opened\n")
        } catch {
            print("FAIL: Could not open SMC: \(error)")
            exit(1)
        }

        defer {
            try? smc.close()
            print("\n✓ SMC connection closed")
        }

        var allPassed = true

        // 3. Read current BCLM value
        do {
            let currentLimit = try smc.readChargeLimit()
            print("Current BCLM value: \(currentLimit)")
        } catch {
            print("FAIL: Could not read BCLM: \(error)")
            allPassed = false
        }

        // 4. Write BCLM to 77, read back, verify
        do {
            try smc.writeChargeLimit(77)
            let readBack = try smc.readChargeLimit()
            print("Wrote BCLM=77, read back: \(readBack)")
            if readBack == 77 {
                print("✓ BCLM write/read verified")
            } else {
                print("WARN: BCLM read back \(readBack), expected 77")
                allPassed = false
            }
        } catch {
            print("FAIL: Could not write/read BCLM: \(error)")
            allPassed = false
        }

        // 5. Restore BCLM to 100
        do {
            try smc.writeChargeLimit(100)
            let restored = try smc.readChargeLimit()
            print("Restored BCLM to 100, read back: \(restored)")
            if restored == 100 {
                print("✓ BCLM restored to 100")
            } else {
                print("WARN: BCLM restore read back \(restored), expected 100")
            }
        } catch {
            print("FAIL: Could not restore BCLM: \(error)")
            allPassed = false
        }

        // 6. Read battery temperature
        do {
            let temp = try smc.readBatteryTemperature()
            print("\nBattery temperature: \(String(format: "%.1f", temp))°C")
            if temp > 0 && temp < 100 {
                print("✓ Temperature reading looks reasonable")
            } else {
                print("WARN: Temperature \(temp)°C seems unusual")
            }
        } catch {
            print("WARN: Could not read battery temperature: \(error)")
            // Not a hard failure — some keys may not exist on all hardware
        }

        // Result
        print("")
        if allPassed {
            print("ALL SMC TESTS PASSED")
        } else {
            print("SOME SMC TESTS FAILED")
            exit(1)
        }
    }
}
