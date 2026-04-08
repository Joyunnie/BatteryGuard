// UserSettings.swift

import Foundation
import Combine
import ServiceManagement

class UserSettings: ObservableObject {
    static let shared = UserSettings()

    /// SMAppService에서 직접 읽기 — UserDefaults에 저장하지 않음
    private var isUpdatingLaunchAtLogin = false
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isUpdatingLaunchAtLogin, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[UserSettings] Launch at login failed: \(error)")
                isUpdatingLaunchAtLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                isUpdatingLaunchAtLogin = false
            }
        }
    }

    @Published var chargeLimit: Int {
        didSet { UserDefaults.standard.set(chargeLimit, forKey: "chargeLimit") }
    }
    @Published var heatProtectionEnabled: Bool {
        didSet { UserDefaults.standard.set(heatProtectionEnabled, forKey: "heatProtection") }
    }
    @Published var heatProtectionThreshold: Double {
        didSet { UserDefaults.standard.set(heatProtectionThreshold, forKey: "heatThreshold") }
    }
    @Published var controlMagSafeLED: Bool {
        didSet { UserDefaults.standard.set(controlMagSafeLED, forKey: "controlMagSafe") }
    }

    init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "chargeLimit") == nil {
            defaults.set(80, forKey: "chargeLimit")
        }
        if defaults.object(forKey: "heatThreshold") == nil {
            defaults.set(40.0, forKey: "heatThreshold")
        }

        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.chargeLimit = defaults.integer(forKey: "chargeLimit")
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.heatProtectionThreshold = defaults.double(forKey: "heatThreshold")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")
    }
}
