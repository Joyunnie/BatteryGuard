// MenuBarView.swift
// 메뉴바 클릭 시 표시되는 드롭다운 뷰

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var controller: ChargeController
    @EnvironmentObject var monitor: BatteryMonitor
    @EnvironmentObject var settings: UserSettings

    var body: some View {
        VStack(spacing: 12) {
            headerSection
            Divider()
            chargeLimitSection
            Divider()
            quickActions
            Divider()
            statusInfo
            Divider()
            bottomActions
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(controller.currentState.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                }

                if let info = monitor.batteryInfo {
                    Text("\(info.currentCharge)%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }
            }

            Spacer()

            if let info = monitor.batteryInfo {
                BatteryIcon(
                    charge: info.currentCharge,
                    isCharging: info.isCharging,
                    isPluggedIn: info.isPluggedIn
                )
            }
        }
    }

    // MARK: - Charge Limit
    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Charge Limit")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(settings.chargeLimit)%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
            }

            Slider(
                value: Binding(
                    get: { Double(settings.chargeLimit) },
                    set: { controller.setChargeLimit(Int($0)) }
                ),
                in: 20...100,
                step: 5
            )
        }
    }

    // MARK: - Quick Actions
    private var quickActions: some View {
        HStack(spacing: 8) {
            ActionButton(
                title: "Top Up",
                icon: "arrow.up.to.line",
                isActive: controller.isTopUpActive,
                action: {
                    if controller.isTopUpActive {
                        controller.cancelTopUp()
                    } else {
                        controller.startTopUp()
                    }
                }
            )

            ActionButton(
                title: "Discharge",
                icon: "arrow.down.to.line",
                isActive: controller.isDischarging,
                action: {
                    if controller.isDischarging {
                        controller.stopDischarge()
                    } else {
                        controller.startDischarge()
                    }
                }
            )
        }
    }

    // MARK: - Status Info
    private var statusInfo: some View {
        VStack(spacing: 4) {
            if let info = monitor.batteryInfo {
                StatusRow(label: "온도", value: String(format: "%.1f°C", info.temperature))
                StatusRow(label: "건강도", value: String(format: "%.1f%%", info.healthPercent))
                StatusRow(label: "사이클", value: "\(info.cycleCount)")
                StatusRow(label: "전류", value: "\(info.amperage)mA")

                if controller.heatProtectionTriggered {
                    HStack {
                        Image(systemName: "thermometer.sun.fill")
                            .foregroundColor(.red)
                        Text("Heat Protection 발동")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Bottom Actions
    private var bottomActions: some View {
        HStack {
            Button("Dashboard") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .font(.system(size: 11))

            Spacer()

            Button("Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .font(.system(size: 11))

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    private var stateColor: Color {
        switch controller.currentState {
        case .charging, .topUp: return .green
        case .chargingPaused: return .orange
        case .discharging: return .blue
        case .calibrating: return .purple
        case .notConnected: return .gray
        }
    }
}

// MARK: - Sub-components

struct ActionButton: View {
    let title: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }
}

struct BatteryIcon: View {
    let charge: Int
    let isCharging: Bool
    let isPluggedIn: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary, lineWidth: 1.5)
                .frame(width: 36, height: 18)

            Rectangle()
                .fill(Color.primary)
                .frame(width: 3, height: 8)
                .offset(x: 19)

            RoundedRectangle(cornerRadius: 2)
                .fill(batteryColor)
                .frame(width: max(0, CGFloat(charge) / 100.0 * 30), height: 12)
                .offset(x: CGFloat(charge) / 100.0 * 15 - 15)

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white)
            }
        }
    }

    private var batteryColor: Color {
        if charge <= 20 { return .red }
        if charge <= 50 { return .orange }
        return .green
    }
}
