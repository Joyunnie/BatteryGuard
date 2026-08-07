// SystemSleepInhibitor.swift
// Owns the narrow, passwordless pmset lease used while charging to a limit.

import Foundation
import Darwin

private let defaultSudoPath = "/usr/bin/sudo"
private let defaultPMSetPath = "/usr/bin/pmset"
private let defaultShellPath = "/bin/sh"
private let defaultSleepBatteryPath = "/usr/local/co.palokaj.battery/battery"

private struct SleepInhibitionLease: Codable, Equatable {
    enum Phase: String, Codable {
        case acquiring
        case owned
    }

    let phase: Phase
    let ownerPID: Int32
    let releaseMarkerPath: String
    let deadline: Date
}

private struct SleepInhibitionJournal {
    private static let maximumBytes = 4_096
    let fileURL: URL

    func acquireProcessLock() throws -> Int32 {
        let directoryURL = fileURL.deletingLastPathComponent()
        try ensureSafeDirectory(directoryURL)
        let lockURL = directoryURL.appendingPathComponent("SleepInhibitionLease.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw posixError() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            throw BatteryError.preflightFailed(
                "another BatteryGuard process is managing the sleep-inhibition lease"
            )
        }
        return descriptor
    }

    static func productionURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport
            .appendingPathComponent("BatteryGuard", isDirectory: true)
            .appendingPathComponent("SleepInhibitionLease.json", isDirectory: false)
    }

    func load() throws -> SleepInhibitionLease? {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CocoaError(.fileReadCorruptFile)
            }
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                offset += count
            }
        }
        return try JSONDecoder().decode(SleepInhibitionLease.self, from: data)
    }

    func save(_ lease: SleepInhibitionLease) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try ensureSafeDirectory(directoryURL)
        let data = try JSONEncoder().encode(lease)
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw CocoaError(.fileWriteUnknown)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".SleepInhibitionLease.\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw posixError() }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary { Darwin.unlink(temporaryURL.path) }
        }

        var offset = 0
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CocoaError(.fileWriteUnknown)
            }
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else { throw posixError() }
        removeTemporary = false
        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw posixError() }
    }

    func clear() throws {
        guard Darwin.unlink(fileURL.path) == 0 || errno == ENOENT else { throw posixError() }
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func ensureSafeDirectory(_ directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var metadata = stat()
        guard Darwin.lstat(directoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

actor SystemSleepInhibitor: SystemSleepInhibiting {
    enum ExecutableTrustPolicy: Sendable, Equatable {
        case production
        case testFixture
    }

    static let shared: SystemSleepInhibitor = {
        let journalURL = try? SleepInhibitionJournal.productionURL()
        return SystemSleepInhibitor(journalURL: journalURL)
    }()

    private let commandRunner: BatteryCommandRunner
    private let watchdogRunner: BatteryCommandRunner
    private let sudoPath: String
    private let pmsetPath: String
    private let shellPath: String
    private let batteryPath: String
    private let journal: SleepInhibitionJournal?
    private let trustPolicy: ExecutableTrustPolicy
    private let processID: Int32
    private let now: @Sendable () -> Date
    private var prepared = false
    private var processLockDescriptor: Int32 = -1

    init(
        commandRunner: BatteryCommandRunner = BatteryCommandRunner(),
        watchdogRunner: BatteryCommandRunner = BatteryCommandRunner(),
        sudoPath: String = defaultSudoPath,
        pmsetPath: String = defaultPMSetPath,
        shellPath: String = defaultShellPath,
        batteryPath: String = defaultSleepBatteryPath,
        journalURL: URL?,
        trustPolicy: ExecutableTrustPolicy = .production,
        processID: Int32 = getpid(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.commandRunner = commandRunner
        self.watchdogRunner = watchdogRunner
        self.sudoPath = sudoPath
        self.pmsetPath = pmsetPath
        self.shellPath = shellPath
        self.batteryPath = batteryPath
        self.journal = journalURL.map(SleepInhibitionJournal.init(fileURL:))
        self.trustPolicy = trustPolicy
        self.processID = processID
        self.now = now
    }

    deinit {
        if processLockDescriptor >= 0 {
            Darwin.close(processLockDescriptor)
        }
    }

    func prepare() async throws {
        guard !prepared else { return }
        guard let journal else {
            throw BatteryError.preflightFailed("sleep inhibition journal is unavailable")
        }
        if processLockDescriptor < 0 {
            processLockDescriptor = try journal.acquireProcessLock()
        }
        try validateExecutable(at: sudoPath)
        try validateExecutable(at: pmsetPath)
        try validateExecutable(at: shellPath)
        try validateExecutable(at: batteryPath)
        try await verifySudoPermission(value: "1")
        try await verifySudoPermission(value: "0")

        if let staleLease = try journal.load(), staleLease.ownerPID != processID {
            guard staleLease.ownerPID > 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let staleMarker = try validatedReleaseMarker(staleLease.releaseMarkerPath)
            if Darwin.kill(staleLease.ownerPID, 0) == 0 || errno == EPERM {
                throw BatteryError.preflightFailed(
                    "another BatteryGuard process owns the sleep-inhibition lease"
                )
            }
            if try await readSleepDisabled() {
                for _ in 0..<15 where try await readSleepDisabled() {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            guard try await readSleepDisabled() == false else {
                throw BatteryError.preflightFailed(
                    "a stale BatteryGuard lease remains enabled; refusing to overwrite an ambiguous external SleepDisabled owner"
                )
            }
            try journal.clear()
            Darwin.unlink(staleMarker.path)
        }
        prepared = true
    }

    func acquire(
        until limit: Int,
        maximumDuration: TimeInterval
    ) async throws -> SleepInhibitionOwnership {
        try await prepare()
        guard UserSettings.chargeLimitRange.contains(limit) else {
            throw BatteryError.invalidChargeLevel(limit)
        }
        let duration = min(max(maximumDuration, 60), 4 * 60 * 60)
        guard let journal else {
            throw BatteryError.preflightFailed("sleep inhibition journal is unavailable")
        }
        if let lease = try journal.load(), lease.ownerPID == processID {
            let marker = try validatedReleaseMarker(lease.releaseMarkerPath)
            if lease.deadline <= now() {
                try await stopChargingForExpiredLease()
                if try await readSleepDisabled() {
                    try await setSleepDisabled(false)
                }
                try createReleaseMarker(marker)
                _ = try? await watchdogRunner.cancelLongRunning()
                try journal.clear()
                Darwin.unlink(marker.path)
                throw SleepInhibitionError.maximumDurationExceeded
            }
            if try await readSleepDisabled() {
                return .batteryGuard
            }
            try createReleaseMarker(marker)
            _ = try? await watchdogRunner.cancelLongRunning()
            try journal.clear()
            Darwin.unlink(marker.path)
        }
        if try await readSleepDisabled() {
            return .external
        }

        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryguard-sleep-\(UUID().uuidString).release")
        let deadline = now().addingTimeInterval(duration)
        var lease = SleepInhibitionLease(
            phase: .acquiring,
            ownerPID: processID,
            releaseMarkerPath: marker.path,
            deadline: deadline
        )
        try journal.save(lease)

        do {
            try await launchWatchdog(
                releaseMarker: marker,
                deadline: deadline,
                runnerTimeout: duration + 60
            )
            try await setSleepDisabled(true)
            lease = SleepInhibitionLease(
                phase: .owned,
                ownerPID: processID,
                releaseMarkerPath: marker.path,
                deadline: deadline
            )
            try journal.save(lease)
            return .batteryGuard
        } catch let operationError {
            do {
                if try await readSleepDisabled() {
                    try await setSleepDisabled(false)
                }
                try createReleaseMarker(marker)
                _ = try? await watchdogRunner.cancelLongRunning()
                try journal.clear()
                Darwin.unlink(marker.path)
            } catch let rollbackError {
                throw BatteryError.commandFailed(
                    "acquire sleep inhibition rollback",
                    -1,
                    "operation: \(operationError.localizedDescription); rollback: \(rollbackError.localizedDescription)"
                )
            }
            throw operationError
        }
    }

    func releaseOwnedInhibition() async throws {
        try await prepare()
        guard let journal else {
            throw BatteryError.preflightFailed("sleep inhibition journal is unavailable")
        }
        guard let lease = try journal.load() else {
            guard try await readSleepDisabled() == false else {
                throw BatteryError.commandFailed(
                    "release sleep inhibition",
                    -1,
                    "SleepDisabled is on but the BatteryGuard ownership lease is missing"
                )
            }
            return
        }
        guard lease.ownerPID == processID else {
            throw BatteryError.commandFailed(
                "release sleep inhibition",
                -1,
                "lease belongs to another process"
            )
        }
        let marker = try validatedReleaseMarker(lease.releaseMarkerPath)
        if try await readSleepDisabled() {
            try await setSleepDisabled(false)
        }
        try createReleaseMarker(marker)
        _ = try? await watchdogRunner.cancelLongRunning()
        try journal.clear()
        Darwin.unlink(marker.path)
    }

    private func verifySudoPermission(value: String) async throws {
        let result = try await commandRunner.run(
            BatteryCommandRunner.Command(
                executable: sudoPath,
                arguments: ["-n", "-l", pmsetPath, "-a", "disablesleep", value],
                environment: minimalEnvironment,
                label: "verify pmset disablesleep \(value) permission",
                timeout: 2
            )
        )
        try requireSuccess(result)
    }

    private func setSleepDisabled(_ disabled: Bool) async throws {
        let result = try await commandRunner.run(
            BatteryCommandRunner.Command(
                executable: sudoPath,
                arguments: ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"],
                environment: minimalEnvironment,
                label: disabled ? "disable system sleep" : "restore system sleep",
                timeout: 5
            )
        )
        try requireSuccess(result)
        guard try await readSleepDisabled() == disabled else {
            throw BatteryError.commandFailed(
                result.command,
                -1,
                "pmset returned success but SleepDisabled did not change"
            )
        }
    }

    private func stopChargingForExpiredLease() async throws {
        for arguments in [["maintain", "stop"], ["charging", "off"]] {
            let result = try await commandRunner.run(
                BatteryCommandRunner.Command(
                    executable: shellPath,
                    arguments: [batteryPath] + arguments,
                    environment: minimalEnvironment,
                    label: "expired sleep inhibition: battery \(arguments.joined(separator: " "))",
                    timeout: 5
                )
            )
            try requireSuccess(result)
        }
    }

    private func readSleepDisabled() async throws -> Bool {
        let result = try await commandRunner.run(
            BatteryCommandRunner.Command(
                executable: pmsetPath,
                arguments: ["-g"],
                environment: minimalEnvironment,
                label: "read SleepDisabled",
                timeout: 2
            )
        )
        try requireSuccess(result)
        guard !result.stdoutWasTruncated,
              let expression = try? NSRegularExpression(
                pattern: #"(?m)^\s*SleepDisabled\s+([01])\s*$"#
              ),
              let match = expression.firstMatch(
                in: result.stdout,
                range: NSRange(result.stdout.startIndex..., in: result.stdout)
              ),
              let valueRange = Range(match.range(at: 1), in: result.stdout) else {
            throw BatteryError.commandFailed(
                result.command,
                -1,
                "pmset output did not contain an exact SleepDisabled value"
            )
        }
        return result.stdout[valueRange] == "1"
    }

    private func launchWatchdog(
        releaseMarker: URL,
        deadline: Date,
        runnerTimeout: TimeInterval
    ) async throws {
        let script = """
        marker=$1
        parent=$2
        deadline=$3
        battery=$4
        sudo=$5
        pmset=$6
        while /bin/kill -0 "$parent" 2>/dev/null; do
          [ -e "$marker" ] && exit 0
          now=$(/bin/date +%s)
          [ "$now" -ge "$deadline" ] && break
          /bin/sleep 2
        done
        [ -e "$marker" ] && exit 0
        "$battery" maintain stop >/dev/null 2>&1 || true
        "$battery" charging off >/dev/null 2>&1 || true
        "$sudo" -n "$pmset" -a disablesleep 0 >/dev/null 2>&1 || true
        """
        _ = try await watchdogRunner.launchLongRunning(
            BatteryCommandRunner.Command(
                executable: shellPath,
                arguments: [
                    "-c", script, "batteryguard-sleep-watchdog", releaseMarker.path,
                    String(processID), String(Int(deadline.timeIntervalSince1970)),
                    batteryPath, sudoPath, pmsetPath
                ],
                environment: minimalEnvironment,
                label: "sleep inhibition watchdog",
                timeout: runnerTimeout,
                outputPolicy: .discard,
                descendantPolicy: .requireProcessGroupExit
            )
        )
    }

    private func createReleaseMarker(_ url: URL) throws {
        let url = try validatedReleaseMarker(url.path)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var metadata = stat()
            guard Darwin.lstat(url.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_size == 0,
                  metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return
        }
        Darwin.close(descriptor)
    }

    private func validatedReleaseMarker(_ path: String) throws -> URL {
        let marker = URL(fileURLWithPath: path).standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let name = marker.lastPathComponent
        guard marker.deletingLastPathComponent() == temporaryDirectory,
              name.hasPrefix("batteryguard-sleep-"),
              name.hasSuffix(".release"),
              name.count > "batteryguard-sleep-.release".count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return marker
    }

    private func requireSuccess(_ result: BatteryCommandResult) throws {
        guard result.termination == .exited, result.exitCode == 0 else {
            throw BatteryError.commandFailed(result.command, result.exitCode, result.combinedOutput)
        }
    }

    private var minimalEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName()
        ]
    }

    private func validateExecutable(at path: String) throws {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0 else {
            throw BatteryError.preflightFailed("missing executable: \(path)")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IFMT != S_IFLNK,
              metadata.st_mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH) != 0 else {
            throw BatteryError.preflightFailed("not a regular executable: \(path)")
        }
        if trustPolicy == .production {
            guard metadata.st_uid == 0,
                  metadata.st_gid == 0,
                  metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                throw BatteryError.preflightFailed("unsafe owner or permissions: \(path)")
            }
        }
    }
}
