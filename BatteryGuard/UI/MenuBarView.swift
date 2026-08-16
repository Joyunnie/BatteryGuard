import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: ChargeController
    @EnvironmentObject private var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            PastelCanvas()

            VStack(alignment: .leading, spacing: 14) {
                headerSection
                chargeLimitSection
                quickActions
                statusInfo
                bottomActions
            }
            .padding(18)
        }
        .tint(BatteryGuardPalette.accent)
        .frame(width: 344)
        .onAppear { monitor.requestPresentationRefresh() }
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            if let info = monitor.batteryInfo {
                PastelBatteryGlyph(
                    charge: info.currentCharge,
                    isCharging: info.isCharging,
                    tint: controller.currentState.presentationTint
                )
            } else {
                Image(systemName: "battery.0percent")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(monitor.batteryInfo.map { String($0.currentCharge) } ?? "--")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                PastelStatusPill(
                    title: controller.currentState.rawValue,
                    tint: controller.currentState.presentationTint,
                    icon: controller.currentState.presentationIcon
                )
            }

            Spacer(minLength: 0)
        }
    }

    private var chargeLimitSection: some View {
        PastelCard(tint: BatteryGuardPalette.lavender, padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("충전 한도", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BatteryGuardPalette.accent)
                    Spacer()
                    Text("\(controller.displayedChargeLimit)%")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(BatteryGuardPalette.accent)
                        .contentTransition(.numericText())
                }

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
                .accessibilityLabel("충전 한도")
                .accessibilityValue("\(controller.displayedChargeLimit) 퍼센트")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MenuActionButton(
                    title: controller.isTopUpActive ? "추가 충전 취소" : "추가 충전",
                    icon: controller.isTopUpActive ? "xmark" : "arrow.up.to.line",
                    tint: BatteryGuardPalette.accent,
                    isActive: controller.isTopUpActive,
                    availability: controller.topUpAvailability
                ) {
                    controller.isTopUpActive ? controller.cancelTopUp() : controller.startTopUp()
                }

                MenuActionButton(
                    title: controller.isDischarging ? "방전 중지" : "방전",
                    icon: controller.isDischarging ? "stop.fill" : "arrow.down.to.line",
                    tint: BatteryGuardPalette.skyInk,
                    isActive: controller.isDischarging,
                    availability: controller.dischargeAvailability
                ) {
                    controller.isDischarging ? controller.stopDischarge() : controller.startDischarge()
                }
            }

            if let denial = primaryAvailabilityDenial {
                Text(denial)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var statusInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info = monitor.batteryInfo {
                HStack(spacing: 8) {
                    CompactMetric(
                        icon: "thermometer.medium",
                        label: "안전 온도",
                        value: controller.safetyTemperatureSnapshot.displayValue,
                        tint: BatteryGuardPalette.peachInk
                    )
                    CompactMetric(
                        icon: "heart.fill",
                        label: "건강도",
                        value: info.healthPercent.map { String(format: "%.1f%%", $0) } ?? "알 수 없음",
                        tint: BatteryGuardPalette.mintInk
                    )
                }

                HStack(spacing: 8) {
                    CompactMetric(
                        icon: "arrow.2.circlepath",
                        label: "사이클",
                        value: BatteryDisplay.measurement(info.cycleCount),
                        tint: BatteryGuardPalette.lavenderInk
                    )
                    CompactMetric(
                        icon: "waveform.path",
                        label: "전류",
                        value: BatteryDisplay.amperage(info.amperage),
                        tint: BatteryGuardPalette.skyInk
                    )
                }
            }

            if controller.heatProtectionPhase != .disabled {
                PastelStatusPill(
                    title: controller.heatProtectionPhase.userDescription,
                    tint: heatProtectionTint,
                    icon: "thermometer.sun.fill"
                )
            }

            ChargeRecoveryStatusView(controller: controller, compact: true)

            if let error = controller.lastError, !controller.hasExternalControlDrift {
                PastelNotice(message: error, kind: .warning)
            }
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 6) {
            Button {
                AppActivationController.shared.showAppWindow {
                    openWindow(id: "dashboard")
                }
            } label: {
                Label("대시보드", systemImage: "rectangle.3.group")
            }

            Spacer(minLength: 4)

            Button {
                AppActivationController.shared.showAppWindow {
                    openWindow(id: "settings")
                }
            } label: {
                Label("설정", systemImage: "gearshape")
            }

            Spacer(minLength: 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("종료", systemImage: "power")
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var primaryAvailabilityDenial: String? {
        controller.chargeLimitAvailability.denialReason
            ?? controller.topUpAvailability.denialReason
            ?? controller.dischargeAvailability.denialReason
    }

    private var heatProtectionTint: Color {
        switch controller.heatProtectionPhase {
        case .blocked, .failed: return BatteryGuardPalette.danger
        case .degraded, .entering, .restoring: return BatteryGuardPalette.warning
        case .monitoring: return BatteryGuardPalette.success
        case .disabled: return .secondary
        }
    }
}

struct ChargeRecoveryStatusView: View {
    @ObservedObject var controller: ChargeController
    var compact = false

    private struct RecoveryContent {
        let title: String
        let detail: String?
        let buttonTitle: String
        let isManualIntervention: Bool
    }

    private var recoveryContent: RecoveryContent? {
        if let drift = controller.externalDriftDescription {
            return RecoveryContent(
                title: drift,
                detail: controller.externalDriftRecoveryDescription,
                buttonTitle: "다시 확인",
                isManualIntervention: false
            )
        }
        if let recovery = controller.manualInterventionRecoveryDescription {
            return RecoveryContent(
                title: "수동 복구 확인이 필요합니다",
                detail: recovery,
                buttonTitle: "안전 상태 다시 확인",
                isManualIntervention: true
            )
        }
        return nil
    }

    var body: some View {
        if let content = recoveryContent {
            VStack(alignment: .leading, spacing: compact ? 6 : 9) {
                Label(content.title, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: compact ? 9.5 : 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        if content.isManualIntervention {
                            await controller.retryManualInterventionRecovery()
                        } else {
                            await controller.reconcileExternalState()
                        }
                    }
                } label: {
                    Label(content.buttonTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isReconcilingExternalState || controller.isCommandPending)
            }
            .foregroundStyle(BatteryGuardPalette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 10 : 14)
            .background(
                BatteryGuardPalette.warning.opacity(0.10),
                in: RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                    .stroke(BatteryGuardPalette.warning.opacity(0.20), lineWidth: 1)
            }
        }
    }
}

private struct MenuActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let isActive: Bool
    let availability: ChargeActionAvailability
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                tint.opacity(isActive ? 0.19 : 0.10),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tint.opacity(isActive ? 0.42 : 0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!availability.isAllowed)
        .opacity(availability.isAllowed ? 1 : 0.48)
        .help(availability.helpText(fallback: title))
    }
}

private struct CompactMetric: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
        .padding(10)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PastelBatteryGlyph: View {
    let charge: Int
    let isCharging: Bool
    let tint: Color

    private var normalizedCharge: CGFloat {
        CGFloat(min(max(charge, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.11))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(tint, lineWidth: 1.6)
                    .frame(width: 31, height: 17)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint)
                    .frame(width: max(3, normalizedCharge * 25), height: 11)
                    .padding(.leading, 3)
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 8)
                    .offset(x: 33)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 31)
                }
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}
