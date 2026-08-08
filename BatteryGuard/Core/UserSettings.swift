// UserSettings.swift

import Foundation
import Combine
import ServiceManagement

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

    nonisolated static let chargeLimitRange = ChargeControlConstraints.limitRange
    nonisolated static let heatProtectionThresholdRange = 20.0...50.0

    nonisolated static func validatedChargeLimit(_ value: Int) -> Int {
        ChargeControlConstraints.validatedLimit(value)
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
    @Published var sleepChargingStrategy: SleepChargingStrategy {
        didSet { defaults.set(sleepChargingStrategy.rawValue, forKey: "sleepChargingStrategy") }
    }

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginService: LaunchAtLoginManaging = MainAppLaunchAtLoginService(),
        batteryControlOwnershipJournalURL: URL? = nil
    ) {
        self.defaults = defaults
        self.launchAtLoginService = launchAtLoginService
        let hadLegacyBatteryControlPreference = defaults.object(forKey: "batteryControlEnabled") != nil
            || defaults.object(forKey: "batteryControlReleasePending") != nil
        let ownershipMigrationWasCompleted = defaults.bool(
            forKey: "batteryControlOwnershipJournalMigrationCompleted"
        )

        if defaults.object(forKey: "chargeLimit") == nil {
            defaults.set(80, forKey: "chargeLimit")
        }
        if defaults.object(forKey: "heatThreshold") == nil {
            defaults.set(40.0, forKey: "heatThreshold")
        }
        let validatedChargeLimit = Self.validatedChargeLimit(defaults.integer(forKey: "chargeLimit"))
        self.chargeLimitStorage = validatedChargeLimit
        self.heatProtectionThresholdStorage = Self.validatedHeatProtectionThreshold(defaults.double(forKey: "heatThreshold"))
        self.launchAtLoginState = LaunchAtLoginState(launchAtLoginService.status)
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")
        self.sleepChargingStrategy = defaults.string(forKey: "sleepChargingStrategy")
            .flatMap(SleepChargingStrategy.init(rawValue:))
            ?? .disabled

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
        } else if hadLegacyBatteryControlPreference && defaults.bool(forKey: "batteryControlEnabled") {
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
                    let initialOwnership: BatteryControlOwnership
                    if !ownershipMigrationWasCompleted && hadLegacyBatteryControlPreference {
                        initialOwnership = legacyOwnership
                    } else {
                        initialOwnership = .system(lastLimit: validatedChargeLimit)
                    }
                    try batteryControlOwnershipJournal.save(initialOwnership)
                    self.batteryControlOwnership = initialOwnership
                }
                defaults.set(true, forKey: "batteryControlOwnershipJournalMigrationCompleted")
                self.batteryControlOwnershipPersistenceError = nil
            } catch {
                self.batteryControlOwnership = .releasing(lastLimit: validatedChargeLimit)
                self.batteryControlOwnershipPersistenceError = error.localizedDescription
            }
        } else {
            // Tests and explicitly journal-less embeddings retain the legacy
            // compatibility surface. Production always resolves a journal URL.
            self.batteryControlOwnership = hadLegacyBatteryControlPreference
                ? legacyOwnership
                : .batteryGuard(lastLimit: validatedChargeLimit)
            self.batteryControlOwnershipPersistenceError = nil
        }

        defaults.set(chargeLimitStorage, forKey: "chargeLimit")
        defaults.set(heatProtectionThresholdStorage, forKey: "heatThreshold")
        defaults.set(batteryControlEnabled, forKey: "batteryControlEnabled")
        defaults.set(batteryControlReleasePending, forKey: "batteryControlReleasePending")
    }

    func requireDurableBatteryControlOwnership() throws {
        if let batteryControlOwnershipPersistenceError {
            throw BatteryError.ownershipPersistenceFailed(
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
                throw BatteryError.ownershipPersistenceFailed(
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
