// BatteryGuardApp.swift
// 앱 진입점 + 메뉴바 아이콘

import SwiftUI
import AppKit

enum AppRuntime {
    static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        NSClassFromString("XCTestCase") != nil
}

enum AppMetadata {
    static var version: String {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !value.isEmpty else {
            return "알 수 없음"
        }
        return value
    }
}

@MainActor
final class AppActivationController {
    static let shared = AppActivationController()

    private let setPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let activate: () -> Void
    private let hasVisibleAppWindow: () -> Bool
    private let diagnostics: DiagnosticLog

    init(
        setPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = { NSApp.setActivationPolicy($0) },
        activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        hasVisibleAppWindow: @escaping () -> Bool = {
            NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
            }
        },
        diagnostics: DiagnosticLog = .shared
    ) {
        self.setPolicy = setPolicy
        self.activate = activate
        self.hasVisibleAppWindow = hasVisibleAppWindow
        self.diagnostics = diagnostics
    }

    @discardableResult
    func setInitialAccessoryPolicy() -> Bool {
        apply(.accessory, operation: "set initial accessory activation policy")
    }

    @discardableResult
    func showAppWindow() -> Bool {
        guard apply(.regular, operation: "set regular activation policy") else { return false }
        activate()
        return true
    }

    @discardableResult
    func restoreAccessoryPolicyIfNeeded() -> Bool {
        guard !hasVisibleAppWindow() else { return true }
        return apply(.accessory, operation: "restore accessory activation policy")
    }

    private func apply(_ policy: NSApplication.ActivationPolicy, operation: String) -> Bool {
        guard setPolicy(policy) else {
            let diagnostics = diagnostics
            Task {
                await diagnostics.record(
                    DiagnosticEvent(
                        category: .lifecycle,
                        operation: operation,
                        outcome: .failed,
                        message: "NSApplication rejected activation policy \(policy.rawValue)"
                    )
                )
            }
            return false
        }
        return true
    }
}

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

        Window("BatteryGuard Settings", id: "settings") {
            SettingsView()
                .environmentObject(UserSettings.shared)
                .environmentObject(ChargeController.shared)
                .frame(width: 450, height: 350)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var initializationTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var terminationApproved = false
    private var windowCloseObserver: NSObjectProtocol?
    private let activationController = AppActivationController.shared

    private var isRunningTests: Bool {
        AppRuntime.isRunningTests
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activationController.setInitialAccessoryPolicy()

        // The unit-test bundle is app-hosted. Never let launching the test host
        // initialize real battery control, history, login items, or SMC writes.
        guard !isRunningTests else { return }

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.activationController.restoreAccessoryPolicyIfNeeded()
            }
        }

        initializationTask = Task { @MainActor in
            do {
                try await ChargeController.shared.initialize()
            } catch {
                guard !Task.isCancelled else { return }
                let alert = NSAlert()
                alert.messageText = "초기화 실패"
                alert.informativeText = """
                \(error.localizedDescription)

                battery CLI를 신뢰할 수 있는 소스에서 수동으로 설치하고
                /usr/local/co.palokaj.battery/battery 경로와 권한을 확인하세요.
                """
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRunningTests else { return .terminateNow }
        if terminationApproved { return .terminateNow }
        if terminationTask != nil { return .terminateLater }

        initializationTask?.cancel()
        initializationTask = nil
        terminationTask = Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            do {
                try await ChargeController.shared.shutdown()
                self.terminationApproved = true
                self.terminationTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                self.terminationTask = nil
                let alert = NSAlert()
                alert.messageText = "안전한 종료 실패"
                alert.informativeText = "\(error.localizedDescription)\n\n배터리 제어 상태를 확인하기 위해 앱을 종료하지 않았습니다."
                alert.alertStyle = .critical
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isRunningTests else { return }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
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
        case .notConnected:
            return "battery.25percent"
        case .unknown:
            return "questionmark.circle"
        }
    }
}
