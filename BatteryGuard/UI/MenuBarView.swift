// MenuBarView.swift
// 메뉴바 클릭 시 표시되는 드롭다운 뷰

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var controller: ChargeController
    @EnvironmentObject var monitor: BatteryMonitor
    @EnvironmentObject var settings: UserSettings
    @Environment(\.openWindow) private var openWindow

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
                Text("충전 한도")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(controller.displayedChargeLimit)%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
            }

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
                controller.isHeatProtectionBlockingControls
            )
        }
    }

    // MARK: - Quick Actions
    private var quickActions: some View {
        HStack(spacing: 8) {
            ActionButton(
                title: "추가 충전",
                icon: "arrow.up.to.line",
                isActive: controller.isTopUpActive,
                isDisabled: !controller.isReady ||
                    controller.isCommandPending ||
                    controller.isChargeLimitPending ||
                    controller.isHeatProtectionBlockingControls ||
                    controller.isDischarging,
                action: {
                    if controller.isTopUpActive {
                        controller.cancelTopUp()
                    } else {
                        controller.startTopUp()
                    }
                }
            )

            ActionButton(
                title: "방전",
                icon: "arrow.down.to.line",
                isActive: controller.isDischarging,
                isDisabled: !controller.isReady ||
                    controller.isCommandPending ||
                    controller.isChargeLimitPending ||
                    controller.isHeatProtectionBlockingControls ||
                    controller.isTopUpActive,
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
                StatusRow(label: "온도", value: info.temperature.map { String(format: "%.1f°C", $0) } ?? "알 수 없음")
                StatusRow(label: "건강도", value: info.healthPercent.map { String(format: "%.1f%%", $0) } ?? "알 수 없음")
                StatusRow(label: "사이클", value: BatteryDisplay.measurement(info.cycleCount))
                StatusRow(label: "전류", value: BatteryDisplay.amperage(info.amperage))

                if controller.heatProtectionTriggered {
                    HStack {
                        Image(systemName: "thermometer.sun.fill")
                            .foregroundColor(.red)
                        Text("열 보호 작동 중")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .padding(.top, 4)
                }
            }

            if let error = controller.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Bottom Actions
    private var bottomActions: some View {
        HStack {
            Button("대시보드") {
                openWindow(id: "dashboard")
                AppActivationController.shared.showAppWindow()
            }
            .font(.system(size: 11))

            Spacer()

            Button("설정") {
                openWindow(id: "settings")
                AppActivationController.shared.showAppWindow()
            }
            .font(.system(size: 11))

            Spacer()

            Button("종료") {
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
        case .notConnected: return .gray
        case .unknown: return .secondary
        }
    }
}

// MARK: - Sub-components

struct ActionButton: View {
    let title: String
    let icon: String
    let isActive: Bool
    var isDisabled: Bool = false
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
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
