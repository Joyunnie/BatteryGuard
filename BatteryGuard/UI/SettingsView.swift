// SettingsView.swift

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: UserSettings
    @EnvironmentObject var controller: ChargeController
    @State private var diagnosticLogError: String?

    var body: some View {
        TabView {
            chargeSettings
                .tabItem { Label("충전", systemImage: "battery.100.bolt") }

            protectionSettings
                .tabItem { Label("보호", systemImage: "shield.fill") }

            appearanceSettings
                .tabItem { Label("외관", systemImage: "paintbrush") }
        }
        .padding()
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private var chargeSettings: some View {
        Form {
            Section("충전 한도") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(controller.displayedChargeLimit) },
                            set: { controller.setChargeLimit(Int($0)) }
                        ),
                        in: 20...100,
                        step: 5
                    )
                    .disabled(
                        !controller.isReady ||
                        controller.isCommandPending ||
                        controller.isDischarging ||
                        controller.isTopUpActive ||
                        controller.hasExternalControlDrift ||
                        controller.isHeatProtectionBlockingControls
                    )
                    Text("\(controller.displayedChargeLimit)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45)
                }

                ExternalDriftStatusView(controller: controller)
            }

            Section("정보") {
                Text("충전 제어는 battery CLI를 통해 관리됩니다. maintain 모드는 sleep/재부팅 후에도 유지됩니다.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var protectionSettings: some View {
        Form {
            Section("열 보호") {
                Toggle(
                    "열 보호 활성화",
                    isOn: Binding(
                        get: { settings.heatProtectionEnabled },
                        set: { controller.setHeatProtectionEnabled($0) }
                    )
                )

                if settings.heatProtectionEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("임계 온도")
                            Spacer()
                            Text(String(format: "%.0f°C", settings.heatProtectionThreshold))
                                .font(.system(.body, design: .monospaced))
                                .bold()
                        }
                        Slider(
                            value: Binding(
                                get: { settings.heatProtectionThreshold },
                                set: { settings.heatProtectionThreshold = $0 }
                            ),
                            in: 20...50,
                            step: 1
                        )
                    }
                }
            }

            Section("설명") {
                Text("""
                배터리 온도가 임계값을 초과하면 자동으로 충전을 중단합니다. \
                고온 충전은 SEI 층 열화를 가속화하여 용량을 빠르게 감소시킵니다. \
                2°C 히스테리시스를 적용하여 ON/OFF 반복을 방지합니다.
                """)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
        }
    }

    private var appearanceSettings: some View {
        Form {
            Section("시작") {
                Toggle(
                    "로그인 시 자동 시작",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
                Text(launchAtLoginDescription)
                    .font(.system(size: 11))
                    .foregroundColor(settings.launchAtLoginState == .requiresApproval ? .orange : .secondary)
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            Section("MagSafe LED") {
                Toggle(
                    "MagSafe LED 제어",
                    isOn: Binding(
                        get: { settings.controlMagSafeLED },
                        set: { controller.setLEDControlEnabled($0) }
                    )
                )
                Text("""
                초록: Limit 도달 / 주황: 충전 중 / 점멸: 방전 중
                MagSafe 3 모델에서만 작동합니다.
                """)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Divider()
                .padding(.vertical, 8)

            Section("진단") {
                Button("진단 로그 보기") {
                    Task {
                        do {
                            let fileURL = try await DiagnosticLog.shared.prepareForViewing()
                            diagnosticLogError = nil
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        } catch {
                            diagnosticLogError = error.localizedDescription
                        }
                    }
                }
                if let diagnosticLogError {
                    Text(diagnosticLogError)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                if let fileURL = DiagnosticLog.shared.fileURL {
                    Text(fileURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("정보") {
                HStack {
                    Text("BatteryGuard")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("v\(AppMetadata.version)")
                        .foregroundColor(.secondary)
                }
                Text("macOS 배터리 관리 메뉴바 앱")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var launchAtLoginDescription: String {
        switch settings.launchAtLoginState {
        case .disabled:
            return "Mac 로그인 시 자동으로 시작하지 않습니다."
        case .enabled:
            return "Mac 로그인 시 BatteryGuard가 자동으로 시작됩니다."
        case .requiresApproval:
            return "시스템 설정 > 일반 > 로그인 항목에서 BatteryGuard를 허용해야 합니다."
        case .unavailable:
            return "로그인 항목 서비스를 찾을 수 없습니다."
        case .unknown(let value):
            return "로그인 항목 상태를 확인할 수 없습니다 (\(value))."
        }
    }
}
