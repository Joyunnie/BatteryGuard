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

    /// SMAppService에서 직접 읽기 — UserDefaults에 저장하지 않음
    private var isUpdatingLaunchAtLogin = false
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isUpdatingLaunchAtLogin, launchAtLogin != oldValue else { return }
            let service = launchAtLoginService
            let action = launchAtLogin ? "register" : "unregister"
            print("[LaunchAtLogin] \(action) — status BEFORE: \(service.status.debugLabel)")
            do {
                if launchAtLogin {
                    try service.register()
                } else {
                    try service.unregister()
                }
                print("[LaunchAtLogin] \(action) returned — status AFTER: \(service.status.debugLabel)")
                // register() can return without throwing yet still not take effect
                let actuallyEnabled = service.status == .enabled
                if launchAtLogin != actuallyEnabled {
                    print("[LaunchAtLogin] ⚠️ status mismatch: toggled \(launchAtLogin) but system reports \(service.status.debugLabel)")
                    isUpdatingLaunchAtLogin = true
                    launchAtLogin = actuallyEnabled
                    isUpdatingLaunchAtLogin = false
                }
            } catch {
                print("[LaunchAtLogin] \(action) failed: \(error)")
                isUpdatingLaunchAtLogin = true
                launchAtLogin = service.status == .enabled
                isUpdatingLaunchAtLogin = false
            }
        }
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
        self.launchAtLogin = launchAtLoginService.status == .enabled
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")

        defaults.set(chargeLimitStorage, forKey: "chargeLimit")
        defaults.set(heatProtectionThresholdStorage, forKey: "heatThreshold")
    }
}
