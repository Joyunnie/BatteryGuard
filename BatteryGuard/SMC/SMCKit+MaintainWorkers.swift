// SMCKit+MaintainWorkers.swift

import Foundation
import Darwin

extension SMCKit {
    func readMaintainWorkerStatusUnlocked(
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
        pgrepOutput: String,
        batteryPath: String
    ) -> MaintainWorkerStatus {
        let workers = parsePgrepMaintainWorkerProcesses(
            pgrepOutput: pgrepOutput,
            batteryPath: batteryPath
        )
        return classifyMaintainWorkers(pidFilePID: pidFilePID, workers: workers)
    }

    static func classifyMaintainWorkers(
        pidFilePID: Int32?,
        pgrepOutput: String,
        processTable: String,
        batteryPath: String,
        identitiesBefore: [Int32: ProcessIdentity],
        identitiesAfter: [Int32: ProcessIdentity]
    ) -> MaintainWorkerStatus {
        classifyMaintainWorkers(
            pidFilePID: pidFilePID,
            workers: stableMaintainWorkers(
                pgrepOutput: pgrepOutput,
                processTable: processTable,
                batteryPath: batteryPath,
                identitiesBefore: identitiesBefore,
                identitiesAfter: identitiesAfter
            )
        )
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

    private static func parsePgrepMaintainWorkerProcesses(
        pgrepOutput: String,
        batteryPath: String
    ) -> [MaintainWorkerProcess] {
        pgrepOutput.split(whereSeparator: \Character.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2,
                  let pid = Int32(fields[0]),
                  pid > 1,
                  let parsed = Self.parseExactMaintainCommand(
                    String(fields[1]),
                    batteryPath: batteryPath
                  ) else {
                return nil
            }
            return MaintainWorkerProcess(
                pid: pid,
                command: String(fields[1]),
                target: parsed.target,
                identity: nil
            )
        }
    }

    static func boundedPgrepMaintainWorkerProcesses(
        pgrepOutput: String,
        batteryPath: String,
        excludingPID: Int32? = nil
    ) throws -> [MaintainWorkerProcess] {
        let parsedCandidates = parsePgrepMaintainWorkerProcesses(
            pgrepOutput: pgrepOutput,
            batteryPath: batteryPath
        ).filter { $0.pid != excludingPID }
        guard parsedCandidates.count <= maximumMaintainWorkerCandidates else {
            throw BatteryError.commandFailed(
                "inspect battery CLI processes",
                -1,
                "refusing unbounded process inspection: \(parsedCandidates.count) exact candidates"
            )
        }
        return parsedCandidates
    }

    private static func parsePSMaintainWorkerProcesses(
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

    private static func stableMaintainWorkers(
        pgrepOutput: String,
        processTable: String,
        batteryPath: String,
        identitiesBefore: [Int32: ProcessIdentity],
        identitiesAfter: [Int32: ProcessIdentity]
    ) -> [MaintainWorkerProcess] {
        let parsedCandidates = parsePgrepMaintainWorkerProcesses(
            pgrepOutput: pgrepOutput,
            batteryPath: batteryPath
        )
        var candidates: [Int32: MaintainWorkerProcess] = [:]
        var duplicatePIDs = Set<Int32>()
        for candidate in parsedCandidates {
            if candidates.updateValue(candidate, forKey: candidate.pid) != nil {
                duplicatePIDs.insert(candidate.pid)
            }
        }
        return parsePSMaintainWorkerProcesses(
            processTable: processTable,
            batteryPath: batteryPath
        ).compactMap { inspected in
            guard !duplicatePIDs.contains(inspected.pid),
                  let candidate = candidates[inspected.pid],
                  candidate.command == inspected.command,
                  candidate.target == inspected.target,
                  let identityBefore = identitiesBefore[inspected.pid],
                  identitiesAfter[inspected.pid] == identityBefore else {
                return nil
            }
            return MaintainWorkerProcess(
                pid: inspected.pid,
                command: inspected.command,
                target: inspected.target,
                identity: identityBefore
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

    func terminateMaintainWorkersUnlocked(
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
            arguments: ["-fl", escapedPath],
            label: "inspect battery CLI processes",
            timeout: try boundedSleepPreparationTimeout(
                maximum: statusCommandTimeout,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ),
            allowedExitCodes: [0, 1]
        )
        guard candidates.exitCode == 0 else { return [] }

        let parsedCandidates = try Self.boundedPgrepMaintainWorkerProcesses(
            pgrepOutput: candidates.stdout,
            batteryPath: batteryPath,
            excludingPID: getpid()
        )
        guard !parsedCandidates.isEmpty else { return [] }

        var identitiesBefore: [Int32: ProcessIdentity] = [:]
        for candidate in parsedCandidates {
            if let identity = try currentIdentity(for: candidate.pid) {
                identitiesBefore[candidate.pid] = identity
            }
        }
        guard !identitiesBefore.isEmpty else { return [] }

        let inspection = try await runProcess(
            executable: "/bin/ps",
            arguments: [
                "-p",
                identitiesBefore.keys.sorted().map(String.init).joined(separator: ","),
                "-o",
                "pid=,pgid=,command="
            ],
            label: "verify battery CLI process identities",
            timeout: try boundedSleepPreparationTimeout(
                maximum: statusCommandTimeout,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            ),
            allowedExitCodes: [0, 1]
        )
        guard inspection.exitCode == 0 else { return [] }

        var identitiesAfter: [Int32: ProcessIdentity] = [:]
        for pid in identitiesBefore.keys {
            if let identity = try currentIdentity(for: pid) {
                identitiesAfter[pid] = identity
            }
        }
        return Self.stableMaintainWorkers(
            pgrepOutput: candidates.stdout,
            processTable: inspection.stdout,
            batteryPath: batteryPath,
            identitiesBefore: identitiesBefore,
            identitiesAfter: identitiesAfter
        )
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

}
