// UserSettings.swift

import Foundation
import Combine
import ServiceManagement
import Darwin

enum BatteryControlOwnership: Equatable, Codable {
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
        let lastLimit = UserSettings.validatedChargeLimit(
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
}

extension SMAppService.Status {
    var debugLabel: String {
        switch self {
        case .notRegistered: return "notRegistered"
        case .enabled:       return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:      return "notFound"
        @unknown default:    return "unknown(\(rawValue))"
        }
    }
}

protocol LaunchAtLoginManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct MainAppLaunchAtLoginService: LaunchAtLoginManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

private struct InertLaunchAtLoginService: LaunchAtLoginManaging {
    var status: SMAppService.Status { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
    case unknown(Int)

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .disabled
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .unavailable
        @unknown default: self = .unknown(status.rawValue)
        }
    }

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
final class UserSettings: ObservableObject {
    static let shared: UserSettings = {
        guard AppRuntime.isRunningTests else { return UserSettings() }
        let suiteName = "com.jiwon.batteryguard.tests.host"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UserSettings(
            defaults: defaults,
            launchAtLoginService: InertLaunchAtLoginService()
        )
    }()

    nonisolated static let chargeLimitRange = 20...100
    nonisolated static let heatProtectionThresholdRange = 20.0...50.0

    nonisolated static func validatedChargeLimit(_ value: Int) -> Int {
        min(max(value, chargeLimitRange.lowerBound), chargeLimitRange.upperBound)
    }

    nonisolated static func validatedHeatProtectionThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return 40.0 }
        return min(max(value, heatProtectionThresholdRange.lowerBound), heatProtectionThresholdRange.upperBound)
    }

    private let defaults: UserDefaults
    private let batteryControlOwnershipJournal: BatteryControlOwnershipJournal?
    var usesStandardDefaults: Bool { defaults === UserDefaults.standard }
    private let launchAtLoginService: LaunchAtLoginManaging
    private var chargeLimitStorage: Int
    private var heatProtectionThresholdStorage: Double

    @Published private(set) var batteryControlOwnership: BatteryControlOwnership
    private(set) var batteryControlOwnershipPersistenceError: String?

    var batteryControlEnabled: Bool {
        if case .batteryGuard = batteryControlOwnership { return true }
        return false
    }

    var batteryControlReleasePending: Bool {
        if case .releasing = batteryControlOwnership { return true }
        return false
    }

    var expectsReleasedBatteryControl: Bool {
        !batteryControlEnabled
    }

    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var launchAtLoginError: String?

    /// Compatibility surface for bindings and tests. The system status remains
    /// the source of truth; requiresApproval is requested but not active.
    var launchAtLogin: Bool {
        get { launchAtLoginState.isRequested }
        set { setLaunchAtLogin(newValue) }
    }

    var chargeLimit: Int {
        get { chargeLimitStorage }
        set {
            let validated = Self.validatedChargeLimit(newValue)
            guard validated != chargeLimitStorage else { return }
            objectWillChange.send()
            chargeLimitStorage = validated
            defaults.set(validated, forKey: "chargeLimit")
        }
    }
    @Published var heatProtectionEnabled: Bool {
        didSet { defaults.set(heatProtectionEnabled, forKey: "heatProtection") }
    }
    var heatProtectionThreshold: Double {
        get { heatProtectionThresholdStorage }
        set {
            let validated = Self.validatedHeatProtectionThreshold(newValue)
            guard validated != heatProtectionThresholdStorage else { return }
            objectWillChange.send()
            heatProtectionThresholdStorage = validated
            defaults.set(validated, forKey: "heatThreshold")
        }
    }
    @Published var controlMagSafeLED: Bool {
        didSet { defaults.set(controlMagSafeLED, forKey: "controlMagSafe") }
    }

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginService: LaunchAtLoginManaging = MainAppLaunchAtLoginService(),
        batteryControlOwnershipJournalURL: URL? = nil
    ) {
        self.defaults = defaults
        self.launchAtLoginService = launchAtLoginService

        if defaults.object(forKey: "chargeLimit") == nil {
            defaults.set(80, forKey: "chargeLimit")
        }
        if defaults.object(forKey: "heatThreshold") == nil {
            defaults.set(40.0, forKey: "heatThreshold")
        }
        if defaults.object(forKey: "batteryControlEnabled") == nil {
            defaults.set(true, forKey: "batteryControlEnabled")
        }

        let validatedChargeLimit = Self.validatedChargeLimit(defaults.integer(forKey: "chargeLimit"))
        self.chargeLimitStorage = validatedChargeLimit
        self.heatProtectionThresholdStorage = Self.validatedHeatProtectionThreshold(defaults.double(forKey: "heatThreshold"))
        self.launchAtLoginState = LaunchAtLoginState(launchAtLoginService.status)
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")

        let journalURL: URL?
        let journalResolutionError: String?
        if let batteryControlOwnershipJournalURL {
            journalURL = batteryControlOwnershipJournalURL
            journalResolutionError = nil
        } else if AppRuntime.isRunningTests {
            journalURL = nil
            journalResolutionError = nil
        } else {
            do {
                journalURL = try BatteryControlOwnershipJournal.productionURL()
                journalResolutionError = nil
            } catch {
                journalURL = nil
                journalResolutionError = error.localizedDescription
            }
        }
        self.batteryControlOwnershipJournal = journalURL.map(BatteryControlOwnershipJournal.init(fileURL:))

        let legacyOwnership: BatteryControlOwnership
        if defaults.bool(forKey: "batteryControlReleasePending") {
            legacyOwnership = .releasing(lastLimit: validatedChargeLimit)
        } else if defaults.bool(forKey: "batteryControlEnabled") {
            legacyOwnership = .batteryGuard(lastLimit: validatedChargeLimit)
        } else {
            legacyOwnership = .system(lastLimit: validatedChargeLimit)
        }
        if let journalResolutionError {
            self.batteryControlOwnership = .releasing(lastLimit: validatedChargeLimit)
            self.batteryControlOwnershipPersistenceError = journalResolutionError
        } else if let batteryControlOwnershipJournal {
            do {
                if let persisted = try batteryControlOwnershipJournal.load() {
                    self.batteryControlOwnership = persisted
                } else {
                    try batteryControlOwnershipJournal.save(legacyOwnership)
                    self.batteryControlOwnership = legacyOwnership
                }
                self.batteryControlOwnershipPersistenceError = nil
            } catch {
                self.batteryControlOwnership = .releasing(lastLimit: validatedChargeLimit)
                self.batteryControlOwnershipPersistenceError = error.localizedDescription
            }
        } else {
            self.batteryControlOwnership = legacyOwnership
            self.batteryControlOwnershipPersistenceError = nil
        }

        defaults.set(chargeLimitStorage, forKey: "chargeLimit")
        defaults.set(heatProtectionThresholdStorage, forKey: "heatThreshold")
    }

    func requireDurableBatteryControlOwnership() throws {
        if let batteryControlOwnershipPersistenceError {
            throw BatteryError.unsupported(
                "충전 제어 소유권 기록을 읽거나 저장할 수 없습니다: \(batteryControlOwnershipPersistenceError)"
            )
        }
    }

    func beginBatteryControlRelease(lastLimit: Int) throws {
        try persistBatteryControlOwnership(
            .releasing(lastLimit: Self.validatedChargeLimit(lastLimit))
        )
    }

    func completeBatteryControlRelease(lastLimit: Int) throws {
        try persistBatteryControlOwnership(
            .system(lastLimit: Self.validatedChargeLimit(lastLimit))
        )
    }

    func completeBatteryGuardEnable(lastLimit: Int) throws {
        try persistBatteryControlOwnership(
            .batteryGuard(lastLimit: Self.validatedChargeLimit(lastLimit))
        )
    }

    private func persistBatteryControlOwnership(_ ownership: BatteryControlOwnership) throws {
        if let batteryControlOwnershipJournal {
            do {
                try batteryControlOwnershipJournal.save(ownership)
                batteryControlOwnershipPersistenceError = nil
            } catch {
                batteryControlOwnershipPersistenceError = error.localizedDescription
                throw BatteryError.unsupported(
                    "충전 제어 소유권을 안전하게 저장할 수 없습니다: \(error.localizedDescription)"
                )
            }
        }
        batteryControlOwnership = ownership

        // Legacy keys are migration breadcrumbs only. The durable journal is
        // the production safety source of truth.
        defaults.set(batteryControlEnabled, forKey: "batteryControlEnabled")
        defaults.set(batteryControlReleasePending, forKey: "batteryControlReleasePending")
    }

    func setLaunchAtLogin(_ requested: Bool) {
        guard requested != launchAtLoginState.isRequested else { return }
        let action = requested ? "register" : "unregister"
        print("[LaunchAtLogin] \(action) — status BEFORE: \(launchAtLoginService.status.debugLabel)")
        do {
            if requested {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
            let observedStatus = launchAtLoginService.status
            launchAtLoginState = LaunchAtLoginState(observedStatus)
            if launchAtLoginState.isRequested == requested {
                launchAtLoginError = nil
            } else {
                launchAtLoginError = requested
                    ? "로그인 항목 등록 요청 후에도 시스템 상태가 활성화되지 않았습니다."
                    : "로그인 항목 해제 요청 후에도 시스템 상태가 활성 상태입니다."
            }
            print("[LaunchAtLogin] \(action) returned — status AFTER: \(observedStatus.debugLabel)")
        } catch {
            launchAtLoginState = LaunchAtLoginState(launchAtLoginService.status)
            launchAtLoginError = error.localizedDescription
            print("[LaunchAtLogin] \(action) failed: \(error.localizedDescription)")
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginState = LaunchAtLoginState(launchAtLoginService.status)
        launchAtLoginError = nil
    }
}
