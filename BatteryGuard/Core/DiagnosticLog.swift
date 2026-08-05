import Foundation

enum DiagnosticCategory: String, Codable, Sendable {
    case command
    case control
    case history
    case sensor
    case lifecycle
}

struct DiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let operationID: String?
    let operation: String
    let exitCode: Int32?
    let termination: String?
    let stderrSummary: String?
    let stateBefore: String?
    let stateAfter: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        operationID: String? = nil,
        operation: String,
        exitCode: Int32? = nil,
        termination: String? = nil,
        stderrSummary: String? = nil,
        stateBefore: String? = nil,
        stateAfter: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.operationID = operationID
        self.operation = operation
        self.exitCode = exitCode
        self.termination = termination
        self.stderrSummary = stderrSummary.map(Self.summarize)
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
    }

    private static func summarize(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(500))
    }
}

extension DiagnosticEvent {
    init(commandResult result: BatteryCommandResult) {
        let termination: String
        switch result.termination {
        case .exited: termination = "exited"
        case .uncaughtSignal(let signal): termination = "signal(\(signal))"
        case .timedOut: termination = "timedOut"
        case .cancelled: termination = "cancelled"
        }
        self.init(
            id: result.commandID,
            category: .command,
            operationID: result.commandID.uuidString,
            operation: result.command,
            exitCode: result.exitCode,
            termination: termination,
            stderrSummary: result.stderr,
            stateAfter: result.command.contains("status_csv")
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )
    }
}

actor DiagnosticLog {
    static let disabled = DiagnosticLog(fileURL: nil, capacity: 0)
    static let shared = DiagnosticLog(fileURL: productionFileURL(), capacity: 100)

    nonisolated let fileURL: URL?

    private let capacity: Int
    private var events: [DiagnosticEvent]
    private var hasLoadedFromDisk = false
    private(set) var persistenceError: String?

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
        persist()
    }

    func recentEvents() -> [DiagnosticEvent] {
        loadFromDiskIfNeeded()
        return events
    }

    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([DiagnosticEvent].self, from: data)
            events = Array(decoded.suffix(capacity))
        } catch {
            persistenceError = error.localizedDescription
            print("[DiagnosticLog] Read failed: \(error.localizedDescription)")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encode(events, to: fileURL)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            print("[DiagnosticLog] Write failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func encode(_ events: [DiagnosticEvent], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(events).write(to: fileURL, options: .atomic)
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
