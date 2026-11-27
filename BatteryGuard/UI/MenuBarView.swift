import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: ChargeController
    @EnvironmentObject private var monitor: BatteryMonitor
    @Environment(\.openWindow) private var openWindow

    private var showsMonitoringModeCard: Bool {
        controller.isBatteryControlDisabled && !controller.hasExternalControlDrift
    }

    private var showsUnsupportedControlCard: Bool {
        controller.isChargeControlUnsupported
            && !controller.isBatteryControlDisabled
            && !controller.hasExternalControlDrift
    }

    var body: some View {
        ZStack {
            BatteryGuardCanvas()

            VStack(alignment: .leading, spacing: 12) {
                headerSection

                if showsMonitoringModeCard {
                    monitoringModeSection
                } else if showsUnsupportedControlCard {
                    ChargeRecoveryStatusView(
                        controller: controller,
                        presentation: controller.batteryPresentation,
                        compact: true,
                        titleOverride: "SMC 충전 제어 불가"
                    )
                } else {
                    chargeLimitSection
                    quickActions
                }

                statusInfo

                Divider()
                    .overlay(BatteryGuardPalette.borderSubtle)

                bottomActions
            }
            .padding(16)
        }
        .tint(BatteryGuardPalette.accent)
        .frame(width: 348)
        .onAppear {
            monitor.requestPresentationRefresh()
            controller.refreshNativeChargeLimit()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            if let info = monitor.batteryInfo {
                BatteryLevelGlyph(
                    charge: info.currentCharge,
                    isCharging: controller.batteryPresentation.showsChargingBolt,
                    tint: controller.batteryPresentation.tone.presentationTint
                )
            } else {
                Image(systemName: "battery.0percent")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(
                        BatteryGuardPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(monitor.batteryInfo.map { String($0.currentCharge) } ?? "--")
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                StatusPill(
                    title: controller.batteryPresentation.statusTitle,
                    tint: controller.batteryPresentation.tone.presentationTint,
                    icon: controller.batteryPresentation.statusIcon
                )

                if let detail = controller.batteryPresentation.activityDetail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var monitoringModeSection: some View {
        SurfaceCard(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("macOS 충전 제어", systemImage: "eye.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BatteryGuardPalette.info)
                    Spacer()
                    Text(controller.nativeChargeLimitStatus.summaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                Text("실시간 전력, 안전 온도, 7일 충전 이력을 모니터링하고 있습니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("macOS 배터리 설정 열기", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var chargeLimitSection: some View {
        SurfaceCard(padding: 13) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("충전 한도", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(controller.displayedChargeLimit)%")
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MenuActionButton(
                    title: controller.isTopUpActive ? "추가 충전 취소" : "추가 충전",
                    icon: controller.isTopUpActive ? "xmark" : "arrow.up.to.line",
                    isActive: controller.isTopUpActive,
                    availability: controller.topUpAvailability
                ) {
                    controller.isTopUpActive ? controller.cancelTopUp() : controller.startTopUp()
                }

                MenuActionButton(
                    title: controller.isDischarging ? "방전 중지" : "방전",
                    icon: controller.isDischarging ? "stop.fill" : "arrow.down.to.line",
                    isActive: controller.isDischarging,
                    availability: controller.dischargeAvailability
                ) {
                    controller.isDischarging ? controller.stopDischarge() : controller.startDischarge()
                }
            }

            if let denial = primaryAvailabilityDenial {
                Text(denial)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var statusInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info = monitor.batteryInfo {
                telemetryGrid(info: info)
            }

            if let heatWarning = controller.monitoringHeatWarningMessage {
                StatusNotice(message: heatWarning, kind: .warning)
            }

            if controller.heatProtectionPhase != .disabled {
                StatusPill(
                    title: controller.heatProtectionPhase.userDescription,
                    tint: heatProtectionTint,
                    icon: "thermometer.sun.fill"
                )
            }

            if !showsUnsupportedControlCard {
                ChargeRecoveryStatusView(
                    controller: controller,
                    presentation: controller.batteryPresentation,
                    compact: true
                )
            }

            if let error = controller.lastError,
               !controller.hasExternalControlDrift,
               !showsUnsupportedControlCard {
                StatusNotice(message: error, kind: .warning)
            }
        }
    }

    private func telemetryGrid(info: BatteryInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TelemetryCell(
                    icon: "thermometer.medium",
                    label: "안전 온도",
                    value: controller.safetyTemperatureSnapshot.displayValue,
                    highlightTint: controller.monitoringHeatWarningMessage != nil ? BatteryGuardPalette.warning : nil
                )
                Rectangle()
                    .fill(BatteryGuardPalette.borderSubtle)
                    .frame(width: 1)
                TelemetryCell(
                    icon: "heart.fill",
                    label: "건강도",
                    value: info.healthPercent.map { String(format: "%.1f%%", $0) } ?? "알 수 없음",
                    highlightTint: nil
                )
            }

            Rectangle()
                .fill(BatteryGuardPalette.borderSubtle)
                .frame(height: 1)

            HStack(spacing: 0) {
                TelemetryCell(
                    icon: "arrow.2.circlepath",
                    label: "사이클",
                    value: BatteryDisplay.measurement(info.cycleCount),
                    highlightTint: nil
                )
                Rectangle()
                    .fill(BatteryGuardPalette.borderSubtle)
                    .frame(width: 1)
                TelemetryCell(
                    icon: "waveform.path",
                    label: "전류",
                    value: BatteryDisplay.amperage(info.amperage),
                    highlightTint: nil
                )
            }
        }
        .background(
            BatteryGuardPalette.surface,
            in: RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
                .stroke(BatteryGuardPalette.border, lineWidth: 1)
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 4) {
            MenuFooterButton(title: "대시보드", icon: "rectangle.3.group") {
                AppActivationController.shared.showAppWindow {
                    openWindow(id: "dashboard")
                }
            }

            Spacer(minLength: 4)

            MenuFooterButton(title: "설정", icon: "gearshape") {
                AppActivationController.shared.showAppWindow {
                    openWindow(id: "settings")
                }
            }

            Spacer(minLength: 4)

            MenuFooterButton(title: "종료", icon: "power", isSubtle: true) {
                NSApplication.shared.terminate(nil)
            }
        }
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
    let presentation: BatteryPresentation
    var compact = false
    var titleOverride: String? = nil

    private struct RecoveryContent {
        let title: String
        let icon: String
        let tint: Color
        let detail: String?
        let observed: String?
        let isManualRecovery: Bool
        let maintainRecoveryLimit: Int?
    }

    private var recoveryContent: RecoveryContent? {
        if let drift = controller.externalDriftDescription {
            return RecoveryContent(
                title: titleOverride ?? drift,
                icon: "arrow.triangle.2.circlepath",
                tint: BatteryGuardPalette.warning,
                detail: controller.externalDriftRecoveryDescription,
                observed: nil,
                isManualRecovery: false,
                maintainRecoveryLimit: nil
            )
        }
        if let recovery = controller.manualInterventionRecoveryDescription {
            let recoveryLimit: Int?
            if case .restoreMaintain(let limit) = controller.manualRecoveryContext?.target {
                recoveryLimit = limit
            } else {
                recoveryLimit = nil
            }
            return RecoveryContent(
                title: titleOverride ?? presentation.statusTitle,
                icon: presentation.statusIcon,
                tint: presentation.tone.presentationTint,
                detail: recovery,
                observed: controller.manualRecoveryObservedDescription,
                isManualRecovery: true,
                maintainRecoveryLimit: recoveryLimit
            )
        }
        return nil
    }

    var body: some View {
        if let content = recoveryContent {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: content.icon)
                        .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
                        .foregroundStyle(content.tint)
                        .padding(.top, 1)
                    Text(content.title)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(content.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let observed = content.observed {
                    Text(observed)
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        recoveryButtons(content)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        recoveryButtons(content)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 12 : 14)
            .background(
                content.tint.opacity(0.08),
                in: RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
                    .stroke(content.tint.opacity(0.24), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func recoveryButtons(_ content: RecoveryContent) -> some View {
        if controller.isChargeControlUnsupported && !controller.isBatteryControlDisabled {
            Button {
                controller.disableBatteryGuardControl()
            } label: {
                Label("모니터링 전용으로 전환", systemImage: "eye")
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!controller.canDisableBatteryGuardControl)
            .help("BatteryGuard 충전 제어를 해제하고 macOS 제어(모니터링 전용)로 전환합니다.")
        }

        if let limit = content.maintainRecoveryLimit {
            Button {
                controller.restoreMaintainFromManualRecovery()
            } label: {
                Label("Maintain \(limit)% 복원", systemImage: "bolt.badge.checkmark")
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!controller.explicitMaintainRecoveryAvailability.isAllowed)
            .help(
                controller.explicitMaintainRecoveryAvailability.helpText(
                    fallback: "검증 후 Maintain \(limit)%를 명시적으로 복원합니다."
                )
            )
        }

        Button {
            Task {
                if content.isManualRecovery {
                    await controller.refreshManualRecoveryStatus()
                } else {
                    await controller.reconcileExternalState()
                }
            }
        } label: {
            Label(controller.manualRecoveryRefreshTitle, systemImage: "arrow.clockwise")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(
            content.isManualRecovery
                ? !controller.manualRecoveryRefreshAvailability.isAllowed
                : controller.isReconcilingExternalState || controller.isCommandPending
        )
        .help(
            content.isManualRecovery
                ? controller.manualRecoveryRefreshAvailability.helpText(
                    fallback: "실제 CLI 상태만 다시 읽습니다."
                )
                : "외부 CLI 상태만 다시 읽습니다."
        )
    }
}

private struct MenuActionButton: View {
    let title: String
    let icon: String
    let isActive: Bool
    let availability: ChargeActionAvailability
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.white : (availability.isAllowed ? Color.primary : Color.secondary))
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                backgroundFill,
                in: RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
                    .stroke(borderStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!availability.isAllowed)
        .opacity(availability.isAllowed ? 1 : 0.48)
        .onHover { hovering in
            guard availability.isAllowed else {
                isHovered = false
                return
            }
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    isHovered = hovering
                }
            }
        }
        .help(availability.helpText(fallback: title))
    }

    private var backgroundFill: Color {
        if isActive { return BatteryGuardPalette.accent }
        if isHovered { return BatteryGuardPalette.hoverFill }
        return BatteryGuardPalette.surface
    }

    private var borderStroke: Color {
        isActive ? BatteryGuardPalette.accent : BatteryGuardPalette.border
    }
}

private struct TelemetryCell: View {
    let icon: String
    let label: String
    let value: String
    let highlightTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(highlightTint ?? BatteryGuardPalette.neutralInk)
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(highlightTint ?? .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct MenuFooterButton: View {
    let title: String
    let icon: String
    var isSubtle = false
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSubtle ? .secondary : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    isHovered ? BatteryGuardPalette.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: BatteryGuardRadius.iconBadge, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    isHovered = hovering
                }
            }
        }
    }
}

private struct BatteryLevelGlyph: View {
    let charge: Int
    let isCharging: Bool
    let tint: Color

    private var normalizedCharge: CGFloat {
        CGFloat(min(max(charge, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
                .fill(tint.opacity(0.11))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .stroke(tint, lineWidth: 1.5)
                    .frame(width: 28, height: 15.5)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(tint)
                    .frame(width: max(3, normalizedCharge * 22), height: 9.5)
                    .padding(.leading, 3)
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: 7)
                    .offset(x: 30)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 28)
                }
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}
