// UserSettings.swift

import Foundation
import Combine

class UserSettings: ObservableObject {
    static let shared = UserSettings()

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

        self.chargeLimit = defaults.integer(forKey: "chargeLimit")
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.heatProtectionThreshold = defaults.double(forKey: "heatThreshold")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")
    }
}
