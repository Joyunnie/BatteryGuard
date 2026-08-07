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
    static let shared = UserSettings()

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
    private let launchAtLoginService: LaunchAtLoginManaging
    private var chargeLimitStorage: Int
    private var heatProtectionThresholdStorage: Double

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
        launchAtLoginService: LaunchAtLoginManaging = MainAppLaunchAtLoginService()
    ) {
        self.defaults = defaults
        self.launchAtLoginService = launchAtLoginService

        if defaults.object(forKey: "chargeLimit") == nil {
            defaults.set(80, forKey: "chargeLimit")
        }
        if defaults.object(forKey: "heatThreshold") == nil {
            defaults.set(40.0, forKey: "heatThreshold")
        }

        self.chargeLimitStorage = Self.validatedChargeLimit(defaults.integer(forKey: "chargeLimit"))
        self.heatProtectionThresholdStorage = Self.validatedHeatProtectionThreshold(defaults.double(forKey: "heatThreshold"))
        self.launchAtLoginState = LaunchAtLoginState(launchAtLoginService.status)
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")

        defaults.set(chargeLimitStorage, forKey: "chargeLimit")
        defaults.set(heatProtectionThresholdStorage, forKey: "heatThreshold")
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
