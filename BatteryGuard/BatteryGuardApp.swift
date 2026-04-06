// BatteryGuardApp.swift
// 앱 진입점 + 메뉴바 아이콘

import SwiftUI

@main
struct BatteryGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(ChargeController.shared)
                .environmentObject(BatteryMonitor.shared)
                .environmentObject(UserSettings.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("BatteryGuard Dashboard", id: "dashboard") {
            DashboardView()
                .environmentObject(ChargeController.shared)
                .environmentObject(BatteryMonitor.shared)
                .environmentObject(UserSettings.shared)
                .frame(minWidth: 600, minHeight: 500)
        }

        Settings {
            SettingsView()
                .environmentObject(UserSettings.shared)
                .environmentObject(ChargeController.shared)
        }
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try ChargeController.shared.initialize()
        } catch {
            let alert = NSAlert()
            alert.messageText = "SMC 초기화 실패"
            alert.informativeText = """
            \(error.localizedDescription)

            root 권한으로 실행하거나, Helper tool을 설치하세요.
            sudo 로 실행: sudo /path/to/BatteryGuard.app/Contents/MacOS/BatteryGuard
            """
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChargeController.shared.shutdown()
    }
}

// MARK: - MenuBarLabel (Live Status Icons)
struct MenuBarLabel: View {
    @ObservedObject private var controller = ChargeController.shared
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
            if let info = monitor.batteryInfo {
                Text("\(info.currentCharge)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }

    private var iconName: String {
        switch controller.currentState {
        case .charging, .topUp:
            return "bolt.fill"
        case .chargingPaused:
            return "battery.75percent"
        case .discharging:
            return "arrow.down.circle.fill"
        case .calibrating:
            return "arrow.2.circlepath"
        case .notConnected:
            return "battery.25percent"
        }
    }
}
