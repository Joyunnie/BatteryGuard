// SettingsView.swift

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: UserSettings
    @EnvironmentObject var controller: ChargeController
    @State private var diagnosticLogError: String?
    @State private var batterySettingsOpenError: String?
    @State private var showsDisableControlConfirmation = false
    @State private var showsEnableControlConfirmation = false

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
                    .disabled(!controller.chargeLimitAvailability.isAllowed)
                    .help(controller.chargeLimitAvailability.helpText(fallback: "충전 한도 변경"))
                    Text("\(controller.displayedChargeLimit)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45)
                }

                ExternalDriftStatusView(controller: controller)
            }

            Section("충전 제어 소유권") {
                if controller.isBatteryControlDisabled {
                    Label("macOS 제어 / BatteryGuard 모니터링 전용", systemImage: "eye")
                        .foregroundColor(.secondary)
                    if controller.isReleasedControlDrift {
                        Button("제어 해제 다시 시도") {
                            controller.disableBatteryGuardControl()
                        }
                        .disabled(!controller.isReady || controller.isCommandPending)
                    } else {
                        Button("BatteryGuard 제어 켜기") {
                            showsEnableControlConfirmation = true
                        }
                        .disabled(!controller.isReady || controller.isCommandPending)
                    }
                } else {
                    Label("BatteryGuard가 충전 제어 중", systemImage: "checkmark.shield")
                    Button("BatteryGuard 제어 끄기", role: .destructive) {
                        showsDisableControlConfirmation = true
                    }
                    .disabled(!controller.isReady || controller.isCommandPending || controller.hasExternalControlDrift)
                }

                Text("BatteryGuard의 Maintain, Top Up, Discharge, Heat Protection과 macOS Charge Limit를 동시에 사용하지 마세요. 단순 제한만 필요하면 BatteryGuard 제어를 끈 뒤 macOS 배터리 설정에서 Charge Limit를 사용하세요. macOS Charge Limit는 Tahoe 26.4 이상 Apple Silicon Mac에서 제공됩니다.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button("macOS 배터리 설정 열기") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
                          NSWorkspace.shared.open(url) else {
                        batterySettingsOpenError = "macOS 배터리 설정을 열지 못했습니다. 시스템 설정에서 배터리를 직접 여세요."
                        return
                    }
                    batterySettingsOpenError = nil
                }
                if let batterySettingsOpenError {
                    Text(batterySettingsOpenError)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            .confirmationDialog(
                "BatteryGuard 충전 제어를 끌까요?",
                isPresented: $showsDisableControlConfirmation,
                titleVisibility: .visible
            ) {
                Button("제어 끄기", role: .destructive) {
                    controller.disableBatteryGuardControl()
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("실행 중인 Top Up/Discharge와 Maintain을 중지하고 기본 충전을 복원합니다. Heat Protection과 MagSafe LED 제어도 꺼집니다.")
            }
            .confirmationDialog(
                "BatteryGuard 충전 제어를 켤까요?",
                isPresented: $showsEnableControlConfirmation,
                titleVisibility: .visible
            ) {
                Button("제어 켜기") {
                    controller.enableBatteryGuardControl()
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("먼저 macOS Battery 설정에서 Charge Limit를 꺼야 두 제어 시스템이 충돌하지 않습니다.")
            }

            Section("정보") {
                Text("충전 제어는 battery CLI를 통해 관리됩니다. Maintain worker는 시스템 잠자기 동안 실행되지 않으므로 아래 잠자기 보호가 충전을 별도로 중지합니다.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var protectionSettings: some View {
        Form {
            Section("잠자기 충전 보호") {
                Picker(
                    "동작",
                    selection: Binding(
                        get: { settings.sleepChargingStrategy },
                        set: { controller.setSleepChargingStrategy($0) }
                    )
                ) {
                    ForEach(SleepChargingStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .disabled(controller.isBatteryControlDisabled || controller.isCommandPending)

                if let description = controller.sleepProtectionState.userDescription {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(sleepProtectionColor)
                }

                Text("잠자기 직전에 Top Up/Discharge를 중단하고 충전 비활성을 검증합니다. 실제 Mac에서 동작을 확인한 뒤 활성화하세요. 시스템이 이미 잠자기를 시작한 뒤에는 실패를 되돌릴 수 없습니다.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("열 보호") {
                Toggle(
                    "열 보호 활성화",
                    isOn: Binding(
                        get: { settings.heatProtectionEnabled },
                        set: { controller.setHeatProtectionEnabled($0) }
                    )
                )
                .disabled(controller.isBatteryControlDisabled)

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
                .disabled(controller.isBatteryControlDisabled)
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

    private var sleepProtectionColor: Color {
        if case .unavailable = controller.sleepProtectionState { return .red }
        return .secondary
    }
}
