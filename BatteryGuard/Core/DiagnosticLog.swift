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
        stateAfter: String? = nil
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

extension DiagnosticEvent {
    init(commandResult result: BatteryCommandResult) {
        let outcome: DiagnosticOutcome
        switch result.termination {
        case .exited: outcome = .exited
        case .uncaughtSignal(let signal): outcome = .signaled(signal)
        case .timedOut: outcome = .timedOut
        case .cancelled: outcome = .cancelled
        }
        self.init(
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

actor DiagnosticLog {
    private static let maximumFileBytes = 1_048_576
    static let disabled = DiagnosticLog(fileURL: nil, capacity: 0)
    static let shared = AppRuntime.isRunningTests
        ? disabled
        : DiagnosticLog(fileURL: productionFileURL(), capacity: 100)

    nonisolated let fileURL: URL?

    private let capacity: Int
    private var events: [DiagnosticEvent]
    private var hasLoadedFromDisk = false
    private(set) var persistenceError: String?
    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "Diagnostics")

    init(fileURL: URL?, capacity: Int = 100) {
        self.fileURL = fileURL
        self.capacity = max(0, capacity)
        self.events = []
    }

    func record(_ event: DiagnosticEvent) {
        guard capacity > 0 else { return }
        loadFromDiskIfNeeded()
        events.append(event)
        events.sort {
            if $0.timestamp == $1.timestamp { return $0.id.uuidString < $1.id.uuidString }
            return $0.timestamp < $1.timestamp
        }
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        do {
            try persist()
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
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
        do {
            try persist()
            return fileURL
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Prepare for viewing failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        guard let fileURL else { return }
        do {
            guard let data = try Self.readBoundedRegularFile(fileURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([DiagnosticEvent].self, from: data)
            events = Array(decoded.suffix(capacity))
        } catch {
            persistenceError = error.localizedDescription
            logger.error("Read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.encode(events, to: fileURL)
        persistenceError = nil
    }

    private nonisolated static func encode(_ events: [DiagnosticEvent], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(events)
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: fileURL, options: .atomic)
        guard Darwin.chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
