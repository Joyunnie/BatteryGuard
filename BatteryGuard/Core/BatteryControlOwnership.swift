import Foundation
import Darwin

enum BatteryControlOwnership: Equatable, Codable, Sendable {
    case batteryGuard(lastLimit: Int)
    case releasing(lastLimit: Int)
    case system(lastLimit: Int)

    private enum CodingKeys: String, CodingKey {
        case owner
        case lastLimit
    }

    private enum Owner: String, Codable {
        case batteryGuard
        case releasing
        case system
    }

    var lastLimit: Int {
        switch self {
        case .batteryGuard(let lastLimit), .releasing(let lastLimit), .system(let lastLimit):
            return lastLimit
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let owner = try container.decode(Owner.self, forKey: .owner)
        let lastLimit = ChargeControlConstraints.validatedLimit(
            try container.decode(Int.self, forKey: .lastLimit)
        )
        switch owner {
        case .batteryGuard: self = .batteryGuard(lastLimit: lastLimit)
        case .releasing: self = .releasing(lastLimit: lastLimit)
        case .system: self = .system(lastLimit: lastLimit)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let owner: Owner
        switch self {
        case .batteryGuard: owner = .batteryGuard
        case .releasing: owner = .releasing
        case .system: owner = .system
        }
        try container.encode(owner, forKey: .owner)
        try container.encode(lastLimit, forKey: .lastLimit)
    }
}

struct BatteryControlOwnershipJournal {
    private static let maximumBytes = 4_096
    let fileURL: URL

    static func productionURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport
            .appendingPathComponent("BatteryGuard", isDirectory: true)
            .appendingPathComponent("BatteryControlOwnership.json", isDirectory: false)
    }

    func load() throws -> BatteryControlOwnership? {
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
        return try JSONDecoder().decode(BatteryControlOwnership.self, from: data)
    }

    func save(_ ownership: BatteryControlOwnership) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateAndSecureDirectory(directoryURL)

        let data = try JSONEncoder().encode(ownership)
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw CocoaError(.fileWriteUnknown)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".BatteryControlOwnership.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw posixError() }

        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
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
        shouldRemoveTemporaryFile = false

        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func validateAndSecureDirectory(_ directoryURL: URL) throws {
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0 else { throw posixError() }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard Darwin.chmod(directoryURL.path, mode_t(S_IRWXU)) == 0 else { throw posixError() }
        guard lstat(directoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

enum SystemChargeLimitStatus: Equatable, Sendable {
    case limited(Int)
    case notSet
    case unavailable

    var limitPercent: Int? {
        guard case .limited(let percent) = self else { return nil }
        return percent
    }

    var summaryText: String {
        switch self {
        case .limited(let percent):
            return "macOS 충전 한도 \(percent)%"
        case .notSet:
            return "macOS 충전 한도 미설정"
        case .unavailable:
            return "macOS 설정에서 관리"
        }
    }
}

protocol SystemChargeLimitReading: Sendable {
    func readChargeLimit() async -> SystemChargeLimitStatus
}

struct InertSystemChargeLimitReader: SystemChargeLimitReading {
    let status: SystemChargeLimitStatus

    init(status: SystemChargeLimitStatus = .unavailable) {
        self.status = status
    }

    func readChargeLimit() async -> SystemChargeLimitStatus {
        status
    }
}

final class PMSetSystemChargeLimitReader: SystemChargeLimitReading, @unchecked Sendable {
    private let runner: BatteryCommandRunner

    init(runner: BatteryCommandRunner = BatteryCommandRunner()) {
        self.runner = runner
    }

    func readChargeLimit() async -> SystemChargeLimitStatus {
        guard !AppRuntime.isRunningTests else { return .unavailable }
        do {
            let result = try await runner.run(
                BatteryCommandRunner.Command(
                    executable: "/usr/bin/pmset",
                    arguments: ["-g", "battlimit"],
                    label: "pmset -g battlimit",
                    timeout: 2,
                    expectedExitCodes: [0]
                )
            )
            guard result.isExpectedExit else { return .unavailable }
            return Self.parse(output: result.stdout)
        } catch {
            return .unavailable
        }
    }

    static func parse(output: String) -> SystemChargeLimitStatus {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .unavailable }
        let lowered = normalized.lowercased()
        if lowered.contains("no battery level limits set")
            || lowered.contains("no limit")
            || lowered.contains("disabled") {
            return .notSet
        }
        // Parse explicit percentage or numeric limit reported by pmset -g battlimit.
        let patterns = [
            #"(?i)(?:charge\s*limit|battery\s*level\s*limit|limit)\s*[:=]\s*(\d{2,3})\s*%?"#,
            #"(\d{2,3})\s*%"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            if let match = regex.firstMatch(in: normalized, range: range),
               match.numberOfRanges > 1,
               let captureRange = Range(match.range(at: 1), in: normalized),
               let value = Int(normalized[captureRange]),
               ChargeControlConstraints.limitRange.contains(value) {
                return .limited(value)
            }
        }
        return .unavailable
    }
}
