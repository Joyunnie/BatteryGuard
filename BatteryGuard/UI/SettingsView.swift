// SettingsView.swift

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: UserSettings
    @EnvironmentObject var controller: ChargeController

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
    }

    private var chargeSettings: some View {
        Form {
            Section("Charge Limit") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(settings.chargeLimit) },
                            set: { controller.setChargeLimit(Int($0)) }
                        ),
                        in: 20...100,
                        step: 5
                    )
                    Text("\(settings.chargeLimit)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45)
                }
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
            Section("Heat Protection") {
                Toggle("Heat Protection 활성화", isOn: $settings.heatProtectionEnabled)

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
                            value: $settings.heatProtectionThreshold,
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
            Section("MagSafe LED") {
                Toggle("MagSafe LED 제어", isOn: $settings.controlMagSafeLED)
                Text("""
                초록: Limit 도달 / 주황: 충전 중 / 점멸: 방전 중
                MagSafe 3 모델에서만 작동합니다.
                """)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Divider()
                .padding(.vertical, 8)

            Section("정보") {
                HStack {
                    Text("BatteryGuard")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("v1.0")
                        .foregroundColor(.secondary)
                }
                Text("macOS 배터리 관리 메뉴바 앱")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}
