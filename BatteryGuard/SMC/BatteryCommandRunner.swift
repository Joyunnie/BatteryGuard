// BatteryCommandRunner.swift
// Serial child-process scheduler with bounded output and process-group cleanup.

import Foundation
import Darwin

enum BatteryCommandTermination: Equatable, Sendable {
    case exited
    case uncaughtSignal(Int32)
    case timedOut
    case cancelled
}

struct BatteryCommandResult: Equatable, Sendable {
    let commandID: UUID
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let termination: BatteryCommandTermination

    var combinedOutput: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BatteryCommandRunnerError: Error, LocalizedError, Sendable {
    case spawnFailed(command: String, code: Int32, message: String)
    case cancellationFailed(command: String, message: String)
    case runnerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let command, let code, let message):
            return "Could not start \(command) (\(code)): \(message)"
        case .cancellationFailed(let command, let message):
            return "Could not stop \(command): \(message)"
        case .runnerUnavailable(let message):
            return "Command runner is unavailable: \(message)"
        }
    }
}

actor BatteryCommandRunner {
    private final class BoundedOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var isClosed = false

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard data.count < BatteryCommandRunner.outputLimit else { return }
            data.append(chunk.prefix(BatteryCommandRunner.outputLimit - data.count))
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func markClosed() {
            lock.lock()
            isClosed = true
            lock.unlock()
        }

        func hasFinishedDraining() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return isClosed
        }
    }

    enum OutputPolicy: Sendable {
        case capture
        case discardStdoutCaptureStderr
        case discard
    }

    enum DescendantPolicy: Sendable, Equatable {
        /// The command is complete only after its entire process group exits.
        case requireProcessGroupExit
        /// The launcher may intentionally leave a persistent worker behind.
        case allowPersistentProcessGroup
    }

    struct Command: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
        let label: String
        let timeout: TimeInterval
        let outputPolicy: OutputPolicy
        let descendantPolicy: DescendantPolicy

        init(
            executable: String,
            arguments: [String],
            environment: [String: String]? = nil,
            label: String,
            timeout: TimeInterval = 30,
            outputPolicy: OutputPolicy = .capture,
            descendantPolicy: DescendantPolicy = .requireProcessGroupExit
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.label = label
            self.timeout = timeout
            self.outputPolicy = outputPolicy
            self.descendantPolicy = descendantPolicy
        }
    }

    private enum QueueAction {
        case execute(Command)
        case launchLongRunning(Command)
    }

    private enum QueueOutcome {
        case result(BatteryCommandResult)
        case longRunningID(UUID)
    }

    private struct QueuedAction {
        let id: UUID
        let action: QueueAction
        let continuation: CheckedContinuation<QueueOutcome, Error>
    }

    private struct SpawnedChild {
        let id: UUID
        let command: Command
        let pid: pid_t
        let stdoutBuffer: BoundedOutputBuffer?
        let stderrBuffer: BoundedOutputBuffer?
        let stdoutReadHandle: FileHandle?
        let stderrReadHandle: FileHandle?
        let stdoutDrainTask: Task<Void, Never>?
        let stderrDrainTask: Task<Void, Never>?
    }

    private struct ActiveCommand {
        let child: SpawnedChild
        var requestedTermination: BatteryCommandTermination?
    }

    private struct LongRunningCommand {
        let child: SpawnedChild
        var requestedTermination: BatteryCommandTermination?
    }

    private var queue: [QueuedAction] = []
    private var queueWorker: Task<Void, Never>?
    private var activeCommand: ActiveCommand?
    private var longRunningCommand: LongRunningCommand?
    private var lastLongRunningResult: BatteryCommandResult?
    private var terminalFailure: BatteryCommandRunnerError?
    private let diagnostics: DiagnosticLog

    private let terminationGraceNanoseconds: UInt64 = 1_000_000_000
    private let cancellationAcknowledgementTimeout: TimeInterval = 4
    private static let outputLimit = 64 * 1024

    init(diagnostics: DiagnosticLog = .disabled) {
        self.diagnostics = diagnostics
    }

    func run(_ command: Command) async throws -> BatteryCommandResult {
        let outcome = try await enqueue(.execute(command))
        try Task.checkCancellation()
        guard case .result(let result) = outcome else {
            throw BatteryCommandRunnerError.runnerUnavailable("scheduler returned the wrong result type")
        }
        return result
    }

    func launchLongRunning(_ command: Command) async throws -> UUID {
        let outcome = try await enqueue(.launchLongRunning(command))
        try Task.checkCancellation()
        guard case .longRunningID(let id) = outcome else {
            throw BatteryCommandRunnerError.runnerUnavailable("scheduler returned the wrong launch result")
        }
        return id
    }

    func isLongRunningActive() async -> Bool {
        guard let command = longRunningCommand else { return false }
        guard let waitStatus = pollWaitStatus(pid: command.child.pid) else { return true }
        do {
            _ = try await finalizeLongRunning(
                command,
                terminateRemainingGroup: true,
                knownWaitStatus: waitStatus
            )
        } catch {
            recordTerminalFailure(error)
        }
        return false
    }

    func longRunningResult() async -> BatteryCommandResult? {
        if let command = longRunningCommand,
           let waitStatus = pollWaitStatus(pid: command.child.pid) {
            do {
                _ = try await finalizeLongRunning(
                    command,
                    terminateRemainingGroup: true,
                    knownWaitStatus: waitStatus
                )
            } catch {
                recordTerminalFailure(error)
            }
        }
        return lastLongRunningResult
    }

    @discardableResult
    func cancelLongRunning() async throws -> BatteryCommandResult? {
        guard var command = longRunningCommand else { return lastLongRunningResult }
        command.requestedTermination = .cancelled
        longRunningCommand = command
        do {
            return try await finalizeLongRunning(command, terminateRemainingGroup: true)
        } catch {
            recordTerminalFailure(error)
            throw terminalFailure ?? error
        }
    }

    func cancelAll() async throws {
        let pending = queue
        queue.removeAll()
        for item in pending {
            item.continuation.resume(throwing: CancellationError())
        }

        if var active = activeCommand {
            active.requestedTermination = .cancelled
            activeCommand = active
            let id = active.child.id
            let deadline = monotonicDeadline(after: cancellationAcknowledgementTimeout)
            while activeCommand?.child.id == id, DispatchTime.now().uptimeNanoseconds < deadline {
                await Self.pollDelay()
            }
            if activeCommand?.child.id == id {
                let error = BatteryCommandRunnerError.cancellationFailed(
                    command: active.child.command.label,
                    message: "active command did not acknowledge cancellation"
                )
                terminalFailure = error
                throw error
            }
        }

        _ = try await cancelLongRunning()
        if let terminalFailure { throw terminalFailure }
    }

    private func enqueue(_ action: QueueAction) async throws -> QueueOutcome {
        if let terminalFailure { throw terminalFailure }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                queue.append(QueuedAction(id: id, action: action, continuation: continuation))
                startQueueWorkerIfNeeded()
            }
        } onCancel: {
            Task { await self.cancel(commandID: id) }
        }
    }

    private func startQueueWorkerIfNeeded() {
        guard queueWorker == nil else { return }
        queueWorker = Task { await drainQueue() }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if let terminalFailure {
                item.continuation.resume(throwing: terminalFailure)
                continue
            }

            do {
                switch item.action {
                case .execute(let command):
                    item.continuation.resume(returning: .result(try await execute(command, id: item.id)))
                case .launchLongRunning(let command):
                    let hasActiveLongCommand = await isLongRunningActive()
                    if let terminalFailure { throw terminalFailure }
                    if hasActiveLongCommand, let existing = longRunningCommand {
                        throw BatteryCommandRunnerError.runnerUnavailable(
                            "cannot start \(command.label) while \(existing.child.command.label) is active"
                        )
                    }
                    let child = try spawn(command, id: item.id)
                    lastLongRunningResult = nil
                    longRunningCommand = LongRunningCommand(child: child, requestedTermination: nil)
                    recordDiagnostic(
                        DiagnosticEvent(
                            id: item.id,
                            category: .command,
                            operationID: item.id.uuidString,
                            operation: command.label,
                            termination: "launched"
                        )
                    )
                    item.continuation.resume(returning: .longRunningID(item.id))
                }
            } catch {
                recordFailure(action: item.action, id: item.id, error: error)
                item.continuation.resume(throwing: error)
            }
        }
        queueWorker = nil
        if !queue.isEmpty { startQueueWorkerIfNeeded() }
    }

    private func execute(_ command: Command, id: UUID) async throws -> BatteryCommandResult {
        let deadline = monotonicDeadline(after: command.timeout)
        let child = try spawn(command, id: id)
        activeCommand = ActiveCommand(child: child, requestedTermination: nil)
        var waitStatus: Int32?

        do {
            while waitStatus == nil {
                if activeCommand?.child.id == id,
                   activeCommand?.requestedTermination != nil {
                    waitStatus = try await terminateProcessGroup(child)
                    break
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    if var active = activeCommand, active.child.id == id {
                        active.requestedTermination = .timedOut
                        activeCommand = active
                    }
                    waitStatus = try await terminateProcessGroup(child)
                    break
                }
                waitStatus = pollWaitStatus(pid: child.pid)
                if waitStatus == nil { await Self.pollDelay() }
            }

            let requestedTermination = activeCommand?.child.id == id
                ? activeCommand?.requestedTermination
                : nil
            if command.descendantPolicy == .requireProcessGroupExit,
               processGroupExists(child.pid) {
                waitStatus = try await terminateProcessGroup(
                    child,
                    knownWaitStatus: waitStatus
                )
            }
            activeCommand = nil
            let result = await makeResult(
                child: child,
                waitStatus: waitStatus ?? 0,
                requestedTermination: requestedTermination,
                drainDeadline: command.descendantPolicy == .allowPersistentProcessGroup
                    ? min(deadline, monotonicDeadline(nanoseconds: 250_000_000))
                    : deadline
            )
            recordDiagnostic(DiagnosticEvent(commandResult: result))
            return result
        } catch {
            activeCommand = nil
            let terminalError = error as? BatteryCommandRunnerError ?? .runnerUnavailable(error.localizedDescription)
            terminalFailure = terminalError
            failPendingActions(with: terminalError)
            throw terminalError
        }
    }

    private func cancel(commandID: UUID) async {
        if let index = queue.firstIndex(where: { $0.id == commandID }) {
            let item = queue.remove(at: index)
            item.continuation.resume(throwing: CancellationError())
            return
        }

        if var active = activeCommand, active.child.id == commandID {
            active.requestedTermination = .cancelled
            activeCommand = active
            return
        }

        if longRunningCommand?.child.id == commandID {
            do {
                _ = try await cancelLongRunning()
            } catch {
                recordTerminalFailure(error)
            }
        }
    }

    private func failPendingActions(with error: Error) {
        let pending = queue
        queue.removeAll()
        for item in pending { item.continuation.resume(throwing: error) }
    }

    private func recordTerminalFailure(_ error: Error) {
        let terminalError = error as? BatteryCommandRunnerError
            ?? .runnerUnavailable(error.localizedDescription)
        terminalFailure = terminalError
        failPendingActions(with: terminalError)
    }

    private nonisolated func spawn(_ command: Command, id: UUID) throws -> SpawnedChild {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let fileActionsCode = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsCode == 0 else {
            throw spawnSetupError(command, code: fileActionsCode, operation: "initialize file actions")
        }
        let attributesCode = posix_spawnattr_init(&attributes)
        guard attributesCode == 0 else {
            posix_spawn_file_actions_destroy(&fileActions)
            throw spawnSetupError(command, code: attributesCode, operation: "initialize attributes")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let outputPipe = command.outputPolicy == .capture ? Pipe() : nil
        let errorPipe = command.outputPolicy == .discard ? nil : Pipe()

        if let outputPipe {
            try checkSpawnSetup(
                posix_spawn_file_actions_adddup2(&fileActions, outputPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                command: command,
                operation: "redirect stdout"
            )
            try checkSpawnSetup(
                posix_spawn_file_actions_addclose(&fileActions, outputPipe.fileHandleForReading.fileDescriptor),
                command: command,
                operation: "close child stdout reader"
            )
            if outputPipe.fileHandleForWriting.fileDescriptor != STDOUT_FILENO {
                try checkSpawnSetup(
                    posix_spawn_file_actions_addclose(&fileActions, outputPipe.fileHandleForWriting.fileDescriptor),
                    command: command,
                    operation: "close duplicated child stdout writer"
                )
            }
        } else {
            try checkSpawnSetup(
                posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
                command: command,
                operation: "discard stdout"
            )
        }

        if let errorPipe {
            try checkSpawnSetup(
                posix_spawn_file_actions_adddup2(&fileActions, errorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
                command: command,
                operation: "redirect stderr"
            )
            try checkSpawnSetup(
                posix_spawn_file_actions_addclose(&fileActions, errorPipe.fileHandleForReading.fileDescriptor),
                command: command,
                operation: "close child stderr reader"
            )
            if errorPipe.fileHandleForWriting.fileDescriptor != STDERR_FILENO {
                try checkSpawnSetup(
                    posix_spawn_file_actions_addclose(&fileActions, errorPipe.fileHandleForWriting.fileDescriptor),
                    command: command,
                    operation: "close duplicated child stderr writer"
                )
            }
        } else {
            try checkSpawnSetup(
                posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
                command: command,
                operation: "discard stderr"
            )
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try checkSpawnSetup(
            posix_spawnattr_setflags(&attributes, flags),
            command: command,
            operation: "enable process group"
        )
        try checkSpawnSetup(
            posix_spawnattr_setpgroup(&attributes, 0),
            command: command,
            operation: "create process group"
        )

        let arguments = [command.executable] + command.arguments
        let environment = (command.environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid: pid_t = 0
        let spawnCode = withCStringArray(arguments) { argv in
            withCStringArray(environment) { envp in
                posix_spawn(&pid, command.executable, &fileActions, &attributes, argv, envp)
            }
        }

        guard spawnCode == 0 else {
            try? outputPipe?.fileHandleForReading.close()
            try? outputPipe?.fileHandleForWriting.close()
            try? errorPipe?.fileHandleForReading.close()
            try? errorPipe?.fileHandleForWriting.close()
            throw BatteryCommandRunnerError.spawnFailed(
                command: command.label,
                code: Int32(spawnCode),
                message: String(cString: strerror(spawnCode))
            )
        }

        try? outputPipe?.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForWriting.close()
        let stdoutBuffer = outputPipe.map { _ in BoundedOutputBuffer() }
        let stderrBuffer = errorPipe.map { _ in BoundedOutputBuffer() }
        let stdoutDrainTask = outputPipe.flatMap { pipe in
            stdoutBuffer.map { buffer in
                Task.detached { Self.drain(pipe.fileHandleForReading, into: buffer) }
            }
        }
        let stderrDrainTask = errorPipe.flatMap { pipe in
            stderrBuffer.map { buffer in
                Task.detached { Self.drain(pipe.fileHandleForReading, into: buffer) }
            }
        }

        return SpawnedChild(
            id: id,
            command: command,
            pid: pid,
            stdoutBuffer: stdoutBuffer,
            stderrBuffer: stderrBuffer,
            stdoutReadHandle: outputPipe?.fileHandleForReading,
            stderrReadHandle: errorPipe?.fileHandleForReading,
            stdoutDrainTask: stdoutDrainTask,
            stderrDrainTask: stderrDrainTask
        )
    }

    private nonisolated func checkSpawnSetup(_ code: Int32, command: Command, operation: String) throws {
        guard code == 0 else { throw spawnSetupError(command, code: code, operation: operation) }
    }

    private nonisolated func spawnSetupError(
        _ command: Command,
        code: Int32,
        operation: String
    ) -> BatteryCommandRunnerError {
        BatteryCommandRunnerError.spawnFailed(
            command: command.label,
            code: code,
            message: "could not \(operation): \(String(cString: strerror(code)))"
        )
    }

    private func terminateProcessGroup(
        _ child: SpawnedChild,
        knownWaitStatus: Int32? = nil
    ) async throws -> Int32 {
        var waitStatus = knownWaitStatus ?? pollWaitStatus(pid: child.pid)
        try signalProcessGroup(child, signal: SIGTERM)
        let termDeadline = monotonicDeadline(nanoseconds: terminationGraceNanoseconds)
        while processGroupExists(child.pid), DispatchTime.now().uptimeNanoseconds < termDeadline {
            if waitStatus == nil { waitStatus = pollWaitStatus(pid: child.pid) }
            await Self.pollDelay()
        }

        if processGroupExists(child.pid) {
            try signalProcessGroup(child, signal: SIGKILL)
            let killDeadline = monotonicDeadline(nanoseconds: terminationGraceNanoseconds)
            while processGroupExists(child.pid), DispatchTime.now().uptimeNanoseconds < killDeadline {
                if waitStatus == nil { waitStatus = pollWaitStatus(pid: child.pid) }
                await Self.pollDelay()
            }
        }

        if waitStatus == nil {
            let reapDeadline = monotonicDeadline(nanoseconds: terminationGraceNanoseconds)
            while waitStatus == nil, DispatchTime.now().uptimeNanoseconds < reapDeadline {
                waitStatus = pollWaitStatus(pid: child.pid)
                if waitStatus == nil { await Self.pollDelay() }
            }
        }

        guard !processGroupExists(child.pid), let waitStatus else {
            throw BatteryCommandRunnerError.cancellationFailed(
                command: child.command.label,
                message: "process group \(child.pid) survived SIGKILL or could not be reaped"
            )
        }
        return waitStatus
    }

    private func signalProcessGroup(_ child: SpawnedChild, signal: Int32) throws {
        guard Darwin.kill(-child.pid, signal) != 0 else { return }
        guard errno != ESRCH else { return }
        throw BatteryCommandRunnerError.cancellationFailed(
            command: child.command.label,
            message: "signal \(signal) failed for process group \(child.pid): \(String(cString: strerror(errno)))"
        )
    }

    private func finalizeLongRunning(
        _ command: LongRunningCommand,
        terminateRemainingGroup: Bool,
        knownWaitStatus: Int32? = nil
    ) async throws -> BatteryCommandResult {
        let waitStatus: Int32
        if terminateRemainingGroup, processGroupExists(command.child.pid) {
            waitStatus = try await terminateProcessGroup(
                command.child,
                knownWaitStatus: knownWaitStatus
            )
        } else if let knownWaitStatus {
            waitStatus = knownWaitStatus
        } else if let status = pollWaitStatus(pid: command.child.pid) {
            waitStatus = status
        } else {
            throw BatteryCommandRunnerError.cancellationFailed(
                command: command.child.command.label,
                message: "process status is unavailable"
            )
        }

        let result = await makeResult(
            child: command.child,
            waitStatus: waitStatus,
            requestedTermination: command.requestedTermination,
            drainDeadline: monotonicDeadline(nanoseconds: terminationGraceNanoseconds)
        )
        if longRunningCommand?.child.id == command.child.id { longRunningCommand = nil }
        lastLongRunningResult = result
        recordDiagnostic(DiagnosticEvent(commandResult: result))
        return result
    }

    private func recordFailure(action: QueueAction, id: UUID, error: Error) {
        let operation: String
        switch action {
        case .execute(let command), .launchLongRunning(let command):
            operation = command.label
        }
        recordDiagnostic(
            DiagnosticEvent(
                id: id,
                category: .command,
                operationID: id.uuidString,
                operation: operation,
                termination: "failedBeforeResult",
                stderrSummary: error.localizedDescription
            )
        )
    }

    private func recordDiagnostic(_ event: DiagnosticEvent) {
        let diagnostics = diagnostics
        Task { await diagnostics.record(event) }
    }

    private func makeResult(
        child: SpawnedChild,
        waitStatus: Int32,
        requestedTermination: BatteryCommandTermination?,
        drainDeadline: UInt64
    ) async -> BatteryCommandResult {
        while !capturesFinished(child), DispatchTime.now().uptimeNanoseconds < drainDeadline {
            await Self.pollDelay()
        }

        if child.command.descendantPolicy == .requireProcessGroupExit {
            if child.stdoutBuffer?.hasFinishedDraining() == false {
                try? child.stdoutReadHandle?.close()
            }
            if child.stderrBuffer?.hasFinishedDraining() == false {
                try? child.stderrReadHandle?.close()
            }
        }

        let stdout = Self.decode(child.stdoutBuffer?.snapshot())
        let stderr = Self.decode(child.stderrBuffer?.snapshot())

        return BatteryCommandResult(
            commandID: child.id,
            command: child.command.label,
            exitCode: Self.exitCode(from: waitStatus),
            stdout: stdout,
            stderr: stderr,
            termination: requestedTermination ?? Self.termination(from: waitStatus)
        )
    }

    private func capturesFinished(_ child: SpawnedChild) -> Bool {
        let stdoutFinished = child.stdoutBuffer?.hasFinishedDraining() ?? true
        let stderrFinished = child.stderrBuffer?.hasFinishedDraining() ?? true
        return stdoutFinished && stderrFinished
    }

    private func pollWaitStatus(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        return result == pid ? status : nil
    }

    private func processGroupExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func monotonicDeadline(after seconds: TimeInterval) -> UInt64 {
        let nanoseconds = seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
        return monotonicDeadline(nanoseconds: nanoseconds)
    }

    private func monotonicDeadline(nanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let result = now.addingReportingOverflow(nanoseconds)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private nonisolated func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var nullTerminated = pointers + [nil]
        return nullTerminated.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private nonisolated static func drain(
        _ handle: FileHandle,
        into buffer: BoundedOutputBuffer
    ) {
        while let chunk = readChunk(fileDescriptor: handle.fileDescriptor) {
            buffer.append(chunk)
        }
        buffer.markClosed()
        try? handle.close()
    }

    private nonisolated static func readChunk(fileDescriptor: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == -1, errno == EINTR { continue }
            return nil
        }
    }

    private nonisolated static func pollDelay() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume()
            }
        }
    }

    private nonisolated static func decode(_ data: Data?) -> String {
        guard let data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : signal
    }

    private nonisolated static func termination(from waitStatus: Int32) -> BatteryCommandTermination {
        let signal = waitStatus & 0x7f
        return signal == 0 ? .exited : .uncaughtSignal(signal)
    }
}
