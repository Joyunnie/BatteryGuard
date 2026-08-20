import Foundation
import OSLog
import Darwin

enum DiagnosticCategory: String, Codable, Sendable {
    case command
    case control
    case history
    case sensor
    case lifecycle
}

enum DiagnosticOutcome: Codable, Equatable, Sendable {
    case launched
    case succeeded
    case failed
    case exited
    case signaled(Int32)
    case timedOut
    case cancelled
    case superseded
    case drifted
}

enum DiagnosticContext {
    @TaskLocal static var operationID: UUID?
}

struct SleepSettlementDiagnostic: Codable, Equatable, Sendable {
    let requestID: UUID
    let requestGeneration: UInt64
    let requestKind: SystemSleepRequestKind
    let deadlineUptimeNanoseconds: UInt64
    let completionEvent: SystemSleepCompletionEvent?
}

struct DiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let operationID: UUID?
    let commandID: UUID?
    let operation: String
    let exitCode: Int32?
    let outcome: DiagnosticOutcome
    let message: String?
    let stateBefore: String?
    let stateAfter: String?
    let sleepSettlement: SleepSettlementDiagnostic?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        operationID: UUID? = DiagnosticContext.operationID,
        commandID: UUID? = nil,
        operation: String,
        exitCode: Int32? = nil,
        outcome: DiagnosticOutcome = .succeeded,
        message: String? = nil,
        stateBefore: String? = nil,
        stateAfter: String? = nil,
        sleepSettlement: SleepSettlementDiagnostic? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.operationID = operationID
        self.commandID = commandID
        self.operation = operation
        self.exitCode = exitCode
        self.outcome = outcome
        self.message = message.map(Self.summarize)
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
        self.sleepSettlement = sleepSettlement
    }

    private static func summarize(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(500))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case category
        case operationID
        case commandID
        case operation
        case exitCode
        case outcome
        case message
        case stateBefore
        case stateAfter
        case sleepSettlement
        case termination
        case stderrSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        category = try container.decode(DiagnosticCategory.self, forKey: .category)
        operation = try container.decode(String.self, forKey: .operation)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        stateBefore = try container.decodeIfPresent(String.self, forKey: .stateBefore)
        stateAfter = try container.decodeIfPresent(String.self, forKey: .stateAfter)
        sleepSettlement = try container.decodeIfPresent(
            SleepSettlementDiagnostic.self,
            forKey: .sleepSettlement
        )

        let operationIDText = try container.decodeIfPresent(String.self, forKey: .operationID)
        operationID = operationIDText.flatMap(UUID.init(uuidString:))
        commandID = try container.decodeIfPresent(UUID.self, forKey: .commandID)
            ?? (category == .command ? id : nil)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .stderrSummary)

        if let decodedOutcome = try container.decodeIfPresent(DiagnosticOutcome.self, forKey: .outcome) {
            outcome = decodedOutcome
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .termination)
            outcome = Self.outcome(fromLegacyValue: legacy)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(operationID, forKey: .operationID)
        try container.encodeIfPresent(commandID, forKey: .commandID)
        try container.encode(operation, forKey: .operation)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(stateBefore, forKey: .stateBefore)
        try container.encodeIfPresent(stateAfter, forKey: .stateAfter)
        try container.encodeIfPresent(sleepSettlement, forKey: .sleepSettlement)
    }

    private static func outcome(fromLegacyValue value: String?) -> DiagnosticOutcome {
        switch value {
        case "launched": return .launched
        case "succeeded": return .succeeded
        case "exited": return .exited
        case "timedOut": return .timedOut
        case "cancelled": return .cancelled
        case "superseded": return .superseded
        case "drifted": return .drifted
        case let value? where value.hasPrefix("signal(") && value.hasSuffix(")"):
            let raw = value.dropFirst("signal(".count).dropLast()
            return Int32(raw).map(DiagnosticOutcome.signaled) ?? .failed
        case .some: return .failed
        case .none: return .succeeded
        }
    }
}

private extension DiagnosticEvent {
    enum RetentionPriority: Int {
        case routine
        case contextual
        case safety
    }

    var retentionPriority: RetentionPriority {
        switch category {
        case .control, .lifecycle:
            return .safety
        case .command, .history, .sensor:
            break
        }

        switch outcome {
        case .failed, .signaled, .timedOut, .drifted:
            return .safety
        case .launched, .cancelled, .superseded:
            return .contextual
        case .succeeded:
            return .contextual
        case .exited:
            if exitCode != 0 || message?.isEmpty == false {
                return .safety
            }
            return .routine
        }
    }
}

extension DiagnosticEvent {
    init(commandResult result: BatteryCommandResult, timestamp: Date = Date()) {
        let outcome: DiagnosticOutcome
        switch result.termination {
        case .exited: outcome = .exited
        case .uncaughtSignal(let signal): outcome = .signaled(signal)
        case .timedOut: outcome = .timedOut
        case .cancelled: outcome = .cancelled
        }
        self.init(
            timestamp: timestamp,
            category: .command,
            operationID: result.operationID,
            commandID: result.commandID,
            operation: result.command,
            exitCode: result.exitCode,
            outcome: outcome,
            message: result.stderr,
            stateAfter: result.command.contains("status_csv")
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )
    }
}

private final class DiagnosticSubmissionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private weak var log: DiagnosticLog?
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func bind(to log: DiagnosticLog) {
        lock.withLock { self.log = log }
    }

    func submit(_ event: DiagnosticEvent) {
        lock.withLock {
            generation &+= 1
            let previous = tail
            let log = self.log
            tail = Task {
                await previous?.value
                await log?.record(event)
            }
        }
    }

    func drain() async {
        while true {
            let snapshot = lock.withLock { (generation, tail) }
            await snapshot.1?.value
            let isCurrent = lock.withLock { generation == snapshot.0 }
            if isCurrent { return }
        }
    }
}

actor DiagnosticLog {
    private static let maximumFileBytes = 1_048_576
    static let disabled = DiagnosticLog(fileURL: nil, capacity: 0)
    static let shared = AppRuntime.isRunningTests
        ? disabled
        : DiagnosticLog(fileURL: productionFileURL(), capacity: 100)

    nonisolated let fileURL: URL?
    nonisolated private let submissionQueue: DiagnosticSubmissionQueue

    private let capacity: Int
    private let routineFlushInterval: TimeInterval
    private var events: [DiagnosticEvent]
    private var hasLoadedFromDisk = false
    private var routineFlushTask: Task<Void, Never>?
    private(set) var persistenceError: String?
    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "Diagnostics")

    init(
        fileURL: URL?,
        capacity: Int = 100,
        routineFlushInterval: TimeInterval = 30
    ) {
        self.fileURL = fileURL
        self.submissionQueue = DiagnosticSubmissionQueue()
        self.capacity = max(0, capacity)
        self.routineFlushInterval = routineFlushInterval.isFinite
            ? max(0, routineFlushInterval)
            : 30
        self.events = []
        submissionQueue.bind(to: self)
    }

    nonisolated func submit(_ event: DiagnosticEvent) {
        submissionQueue.submit(event)
    }

    func record(_ event: DiagnosticEvent) {
        guard capacity > 0 else { return }
        loadFromDiskIfNeeded()
        insertRetainingPriority(event)
        if event.retentionPriority == .routine, routineFlushInterval > 0 {
            scheduleRoutineFlushIfNeeded()
        } else {
            persistImmediately(operation: "Write")
        }
    }

    func recentEvents() -> [DiagnosticEvent] {
        loadFromDiskIfNeeded()
        return events
    }

    func prepareForViewing() throws -> URL {
        guard let fileURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "진단 로그 경로를 사용할 수 없습니다."
            ])
        }
        loadFromDiskIfNeeded()
        if let persistenceError {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "진단 로그를 저장하지 못했습니다: \(persistenceError)"
            ])
        }
        routineFlushTask?.cancel()
        routineFlushTask = nil
        do {
            try persist()
            return fileURL
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Prepare for viewing failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func flushPendingEvents() async {
        await submissionQueue.drain()
        routineFlushTask?.cancel()
        routineFlushTask = nil
        persistImmediately(operation: "Flush")
    }

    private func scheduleRoutineFlushIfNeeded() {
        guard fileURL != nil, routineFlushTask == nil else { return }
        let nanoseconds = UInt64(min(routineFlushInterval * 1_000_000_000, Double(UInt64.max)))
        routineFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushScheduledRoutineEvents()
        }
    }

    private func flushScheduledRoutineEvents() {
        routineFlushTask = nil
        persistImmediately(operation: "Scheduled flush")
    }

    private func persistImmediately(operation: String) {
        routineFlushTask?.cancel()
        routineFlushTask = nil
        do {
            try persist()
        } catch {
            persistenceError = error.localizedDescription
            logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        guard let fileURL else { return }
        do {
            guard let data = try Self.readBoundedRegularFile(fileURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                let precise = ISO8601DateFormatter()
                precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = precise.date(from: value) { return date }
                let legacy = ISO8601DateFormatter()
                legacy.formatOptions = [.withInternetDateTime]
                guard let date = legacy.date(from: value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Invalid ISO-8601 diagnostic timestamp"
                    )
                }
                return date
            }
            let decoded = try decoder.decode([DiagnosticEvent].self, from: data)
            events = Self.retainedEvents(decoded, capacity: capacity)
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func insertRetainingPriority(_ event: DiagnosticEvent) {
        if let last = events.last, Self.isOrdered(last, before: event) {
            events.append(event)
        } else {
            var lowerBound = 0
            var upperBound = events.count
            while lowerBound < upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                if Self.isOrdered(events[midpoint], before: event) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            events.insert(event, at: lowerBound)
        }
        if events.count > capacity {
            events.remove(at: Self.evictionIndex(in: events))
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.validateAndSecureDirectory(directoryURL)
        events = try Self.encodeRetainedEventsWithinLimit(events, to: fileURL)
        persistenceError = nil
    }

    private nonisolated static func validateAndSecureDirectory(_ directoryURL: URL) throws {
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard Darwin.chmod(directoryURL.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard lstat(directoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private nonisolated static func retainedEvents(
        _ events: [DiagnosticEvent],
        capacity: Int
    ) -> [DiagnosticEvent] {
        guard capacity > 0 else { return [] }
        var retained = events.sorted(by: isOrdered)
        while retained.count > capacity {
            retained.remove(at: evictionIndex(in: retained))
        }
        return retained
    }

    private nonisolated static func isOrdered(
        _ lhs: DiagnosticEvent,
        before rhs: DiagnosticEvent
    ) -> Bool {
        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.timestamp < rhs.timestamp
    }

    private nonisolated static func evictionIndex(in events: [DiagnosticEvent]) -> Int {
        let lowestPriority = events.map(\.retentionPriority.rawValue).min() ?? 0
        return events.firstIndex {
            $0.retentionPriority.rawValue == lowestPriority
        } ?? events.startIndex
    }

    private nonisolated static func encodeRetainedEventsWithinLimit(
        _ events: [DiagnosticEvent],
        to fileURL: URL
    ) throws -> [DiagnosticEvent] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var retained = events
        var data = try encoder.encode(retained)
        while data.count > maximumFileBytes, !retained.isEmpty {
            retained.remove(at: evictionIndex(in: retained))
            data = try encoder.encode(retained)
        }
        try data.write(to: fileURL, options: .atomic)
        guard Darwin.chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return retained
    }

    private nonisolated static func readBoundedRegularFile(_ fileURL: URL) throws -> Data? {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= maximumFileBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { throw CocoaError(.fileReadCorruptFile) }
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                offset += count
            }
        }
        return data
    }

    private nonisolated static func productionFileURL() -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("BatteryGuard", isDirectory: true)
            .appendingPathComponent("Diagnostics.json")
    }
}
