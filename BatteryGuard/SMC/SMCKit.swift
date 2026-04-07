// SMCKit.swift
// battery CLI 래퍼 + 온도/LED용 raw SMC 읽기
//
// 충전 제어는 battery CLI(battery maintain, discharge 등)에 위임.
// 개별 SMC 키(CHTE, CHIE 등)를 직접 조작하지 않음 — CLI가 전체 SMC 상태를 관리.
// 온도 읽기와 MagSafe LED만 raw smc 바이너리를 직접 사용.

import Foundation

// MARK: - Paths

private let kBatteryPath = "/usr/local/co.palokaj.battery/battery"
private let kSMCBinaryPath = "/usr/local/co.palokaj.battery/smc"

// MARK: - MagSafe LED State (ACLC key)

enum MagSafeLEDState: UInt8 {
    case off = 0x00
    case green = 0x03
    case orange = 0x04
    case auto = 0x05
}

// MARK: - BatteryError

enum BatteryError: Error, LocalizedError, CustomStringConvertible {
    case binaryNotFound(String)
    case commandFailed(String, Int32, String)

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            return "Binary not found at \(path)"
        case .commandFailed(let cmd, let code, let output):
            return "Command failed (\(code)): \(cmd) — \(output)"
        }
    }

    var errorDescription: String? { description }
}

// MARK: - 프로세스 실행 모드
/// battery CLI 명령의 3가지 실행 패턴:
/// - .captureOutput: 즉시 완료 명령 (status, charging on/off, maintain stop). pipe로 출력 캡처.
/// - .daemonSpawn: 래퍼가 nohup으로 데몬을 spawn하고 즉시 종료 (maintain XX). /dev/null + waitUntilExit.
/// - .longRunning: 프로세스 자체가 장시간 실행 (discharge, charge). launch만 하고 대기 안 함.
private enum RunMode {
    case captureOutput
    case daemonSpawn
    case longRunning
}

// MARK: - SMCKit
/// battery CLI를 통한 충전 제어 + raw SMC로 온도/LED 제어.
/// 모든 충전 관련 명령은 battery CLI에 위임하여 SMC 키 충돌을 방지.

final class SMCKit {
    static let shared = SMCKit()

    /// smc 바이너리 사용 가능 여부 (온도/LED용, 없어도 앱은 작동)
    private(set) var smcAvailable = false

    /// 현재 실행 중인 장시간 프로세스 (discharge/charge)
    /// stopDischarge/cancelTopUp에서 terminate() 호출용
    /// 여러 스레드(batteryQueue, main)에서 접근 — lock으로 보호
    private var _runningLongProcess: Process?
    private let longProcessLock = NSLock()

    var runningLongProcess: Process? {
        longProcessLock.lock()
        defer { longProcessLock.unlock() }
        return _runningLongProcess
    }

    /// 파일 존재 여부만 확인 (메인 스레드에서 호출해도 안전)
    func open() throws {
        guard FileManager.default.fileExists(atPath: kBatteryPath) else {
            throw BatteryError.binaryNotFound(
                "battery CLI not installed.\nRun: curl -s https://raw.githubusercontent.com/actuallymentor/battery/main/setup.sh | bash"
            )
        }
        print("[SMCKit] battery CLI found: \(kBatteryPath)")

        smcAvailable = FileManager.default.fileExists(atPath: kSMCBinaryPath)
        if smcAvailable {
            print("[SMCKit] smc binary available (temp/LED)")
        } else {
            print("[SMCKit] smc binary not found — temp/LED features disabled")
        }
    }

    func close() throws {}

    // MARK: - Battery CLI: Charge Maintenance

    /// battery maintain XX — 래퍼가 nohup 데몬을 spawn하고 즉시 종료
    @discardableResult
    func maintain(level: Int) throws -> String {
        return try batteryCommand(["maintain", "\(level)"], mode: .daemonSpawn)
    }

    /// battery maintain stop — 즉시 완료
    @discardableResult
    func maintainStop() throws -> String {
        return try batteryCommand(["maintain", "stop"])
    }

    // MARK: - Battery CLI: Charging On/Off

    @discardableResult
    func chargingOff() throws -> String {
        return try batteryCommand(["charging", "off"])
    }

    @discardableResult
    func chargingOn() throws -> String {
        return try batteryCommand(["charging", "on"])
    }

    // MARK: - Battery CLI: Discharge / Charge
    // 장시간 실행 — launch만 하고 waitUntilExit 안 함.
    // ChargeController의 디스플레이 루프가 IOKit으로 완료를 감지.

    /// battery discharge XX — 목표 %까지 수분~수시간 실행
    @discardableResult
    func discharge(to level: Int) throws -> String {
        return try batteryCommand(["discharge", "\(level)"], mode: .longRunning)
    }

    /// battery charge XX — 목표 %까지 수분~수시간 실행
    @discardableResult
    func charge(to level: Int) throws -> String {
        return try batteryCommand(["charge", "\(level)"], mode: .longRunning)
    }

    /// 실행 중인 장시간 프로세스를 강제 종료 (어느 스레드에서든 안전)
    func terminateLongProcess() {
        longProcessLock.lock()
        guard let proc = _runningLongProcess else {
            longProcessLock.unlock()
            return
        }
        _runningLongProcess = nil
        longProcessLock.unlock()

        if proc.isRunning {
            print("[SMCKit] Terminating long-running process pid=\(proc.processIdentifier)")
            proc.terminate()
        }
    }

    // MARK: - Battery CLI: Status

    func status() throws -> String {
        return try batteryCommand(["status"])
    }

    // MARK: - Battery Temperature (raw SMC read)

    func readBatteryTemperature() throws -> Float {
        guard smcAvailable else {
            throw BatteryError.commandFailed("smc", -1, "smc binary not available")
        }

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
            throw BatteryError.commandFailed("smc temp read", -1, "no temperature sensors found")
        }
        return maxTemp
    }

    // MARK: - MagSafe LED (raw SMC)

    func setMagSafeLED(_ state: MagSafeLEDState) throws {
        guard smcAvailable else { return }
        try smcWrite(key: "ACLC", hexValue: String(format: "%02x", state.rawValue))
    }

    // MARK: - Raw SMC Helpers

    private func smcReadFloat(key: String) throws -> Float {
        let output = try smcRead(key: key)
        if let bracketEnd = output.range(of: "]"),
           let bytesStart = output.range(of: "(bytes") {
            let valueStr = output[bracketEnd.upperBound..<bytesStart.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let val = Float(valueStr) { return val }
        }
        if output.contains("no data") { return 0 }
        throw BatteryError.commandFailed("smc -k \(key) -r", -1, output)
    }

    private func smcRead(key: String) throws -> String {
        let (code, stdout, stderr) = run(kSMCBinaryPath, args: ["-k", key, "-r"])
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || output.contains("Error:") {
            throw BatteryError.commandFailed("smc -k \(key) -r", code,
                (stderr.isEmpty ? output : stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func smcWrite(key: String, hexValue: String) throws {
        let (code, stdout, stderr) = run("/usr/bin/sudo", args: [kSMCBinaryPath, "-k", key, "-w", hexValue])
        let output = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || output.contains("Error:") {
            throw BatteryError.commandFailed("sudo smc -k \(key) -w \(hexValue)", code, output)
        }
    }

    // MARK: - Battery CLI Subprocess

    private var batteryEnv: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/co.palokaj.battery",
            "HOME": home,
            "USER": NSUserName()
        ]
    }

    @discardableResult
    private func batteryCommand(_ args: [String], mode: RunMode = .captureOutput) throws -> String {
        let cmd = "battery \(args.joined(separator: " "))"
        #if DEBUG
        print("[SMCKit] batteryCommand: \(cmd) (mode=\(mode))")
        #endif
        let env = batteryEnv
        let bashArgs = [kBatteryPath] + args

        switch mode {
        case .captureOutput:
            let (code, stdout, stderr) = run("/bin/bash", args: bashArgs, environment: env)
            let output = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if code != 0 {
                print("[SMCKit] \(cmd) FAILED (exit \(code)): \(output)")
                throw BatteryError.commandFailed(cmd, code, output)
            }
            #if DEBUG
            print("[SMCKit] \(cmd) OK\(output.isEmpty ? "" : ": \(output.prefix(200))")")
            #endif
            return output

        case .daemonSpawn:
            let (code, _, _) = runFireAndForget("/bin/bash", args: bashArgs, environment: env)
            if code != 0 {
                print("[SMCKit] \(cmd) FAILED (exit \(code))")
                throw BatteryError.commandFailed(cmd, code, "")
            }
            #if DEBUG
            print("[SMCKit] \(cmd) OK (daemon spawned)")
            #endif
            return ""

        case .longRunning:
            try launchLongRunning("/bin/bash", args: bashArgs, environment: env, label: cmd)
            #if DEBUG
            print("[SMCKit] \(cmd) launched (long-running, no wait)")
            #endif
            return ""
        }
    }

    // MARK: - Process Execution

    private static let processTimeout: TimeInterval = 30

    /// 즉시 완료 명령: pipe로 출력 캡처, 타임아웃 30초
    private func run(_ executable: String, args: [String], environment: [String: String]? = nil) -> (Int32, String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let env = environment { proc.environment = env }

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            #if DEBUG
            print("[SMCKit] Process started, pid=\(proc.processIdentifier): \(executable) \(args.joined(separator: " "))")
            #endif
        } catch {
            print("[SMCKit] Process launch FAILED: \(error)")
            return (-1, "", error.localizedDescription)
        }

        // pipe 버퍼 교착 방지: stdout/stderr 별도 스레드 읽기
        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let timeoutWork = DispatchWorkItem {
            if proc.isRunning {
                print("[SMCKit] TIMEOUT after \(Self.processTimeout)s — killing pid=\(proc.processIdentifier)")
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.processTimeout, execute: timeoutWork)

        proc.waitUntilExit()
        timeoutWork.cancel()
        readGroup.wait()

        #if DEBUG
        print("[SMCKit] Process finished, pid=\(proc.processIdentifier), exit=\(proc.terminationStatus)")
        #endif

        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 데몬 spawn 명령: /dev/null + waitUntilExit (래퍼 스크립트가 즉시 종료)
    private func runFireAndForget(_ executable: String, args: [String], environment: [String: String]? = nil) -> (Int32, String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let env = environment { proc.environment = env }

        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            #if DEBUG
            print("[SMCKit] Process started (daemon-spawn), pid=\(proc.processIdentifier)")
            #endif
        } catch {
            print("[SMCKit] Process launch FAILED: \(error)")
            return (-1, "", error.localizedDescription)
        }

        let timeoutWork = DispatchWorkItem {
            if proc.isRunning {
                print("[SMCKit] TIMEOUT after \(Self.processTimeout)s — killing pid=\(proc.processIdentifier)")
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.processTimeout, execute: timeoutWork)

        proc.waitUntilExit()
        timeoutWork.cancel()

        #if DEBUG
        print("[SMCKit] Process finished (daemon-spawn), pid=\(proc.processIdentifier), exit=\(proc.terminationStatus)")
        #endif
        return (proc.terminationStatus, "", "")
    }

    /// 장시간 실행 명령: launch만 하고 waitUntilExit 안 함.
    /// 이전 장시간 프로세스가 있으면 먼저 종료.
    private func launchLongRunning(_ executable: String, args: [String], environment: [String: String]? = nil, label: String) throws {
        // 이전 장시간 프로세스 정리
        terminateLongProcess()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let env = environment { proc.environment = env }

        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        longProcessLock.lock()
        _runningLongProcess = proc
        longProcessLock.unlock()
        #if DEBUG
        print("[SMCKit] Long-running process launched, pid=\(proc.processIdentifier): \(label)")
        #endif
    }
}
