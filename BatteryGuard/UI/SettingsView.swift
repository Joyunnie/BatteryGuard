import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case charge = "충전"
        case protection = "보호"
        case general = "일반"

        var id: Self { self }

        var icon: String {
            switch self {
            case .charge: return "battery.100percent.bolt"
            case .protection: return "shield.lefthalf.filled"
            case .general: return "slider.horizontal.3"
            }
        }

        var subtitle: String {
            switch self {
            case .charge: return "한도와 제어권"
            case .protection: return "잠자기와 온도"
            case .general: return "시작, LED, 진단"
            }
        }
    }

    @EnvironmentObject private var settings: UserSettings
    @EnvironmentObject private var controller: ChargeController
    @EnvironmentObject private var monitor: BatteryMonitor
    @State private var selection: Destination = .charge
    @State private var hoveredDestination: Destination?
    @State private var diagnosticLogError: String?
    @State private var batterySettingsOpenError: String?
    @State private var showsDisableControlConfirmation = false
    @State private var showsEnableControlConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BatteryGuardCanvas()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 204)

                Rectangle()
                    .fill(BatteryGuardPalette.border)
                    .frame(width: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageHeader
                        selectedPage
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .tint(BatteryGuardPalette.accent)
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
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            monitor.requestPresentationRefresh()
            controller.refreshNativeChargeLimit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BatteryGuardPalette.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        BatteryGuardPalette.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: BatteryGuardRadius.iconBadge, style: .continuous)
                    )
                Text("BatteryGuard")
                    .font(.system(size: 14.5, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            VStack(spacing: 4) {
                ForEach(Destination.allCases) { destination in
                    sidebarButton(destination)
                }
            }

            Spacer()

            Text("v\(AppMetadata.version)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(16)
        .background(BatteryGuardPalette.surface)
    }

    private func sidebarButton(_ destination: Destination) -> some View {
        let isSelected = selection == destination
        let isHovered = hoveredDestination == destination
        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? BatteryGuardPalette.accent : BatteryGuardPalette.neutralInk)
                    .frame(width: 26, height: 26)
                    .background(
                        isSelected
                            ? BatteryGuardPalette.accent.opacity(0.14)
                            : BatteryGuardPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: BatteryGuardRadius.iconBadge, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(destination.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                sidebarRowBackground(isSelected: isSelected, isHovered: isHovered),
                in: RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            let next = hovering ? destination : (hoveredDestination == destination ? nil : hoveredDestination)
            if reduceMotion {
                hoveredDestination = next
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    hoveredDestination = next
                }
            }
        }
        .accessibilityLabel("\(destination.rawValue) 설정")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sidebarRowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return BatteryGuardPalette.accent.opacity(0.10) }
        if isHovered { return BatteryGuardPalette.hoverFill }
        return .clear
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.rawValue)
                .font(.system(size: 22, weight: .bold))
            Text(pageSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var pageSubtitle: String {
        switch selection {
        case .charge: return "충전 한도와 제어 소유권을 관리합니다."
        case .protection: return "잠자기 충전 보호와 온도 경고를 설정합니다."
        case .general: return "자동 실행, MagSafe LED, 진단 로그를 관리합니다."
        }
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .charge: chargeSettings
        case .protection: protectionSettings
        case .general: generalSettings
        }
    }

    private var chargeSettings: some View {
        VStack(spacing: 14) {
            if controller.isBatteryControlDisabled || controller.isChargeControlUnsupported {
                controlOwnershipCard

                if controller.isBatteryControlDisabled && !controller.hasExternalControlDrift {
                    nativeChargeLimitCard
                }
            } else {
                batteryGuardChargeLimitCard
                controlOwnershipCard

                StatusNotice(
                    message: "Maintain worker는 시스템 잠자기 동안 실행되지 않습니다. 잠자기 충전 보호가 이 구간을 별도로 맡습니다.",
                    kind: .info
                )
            }
        }
    }

    private var nativeChargeLimitCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "macOS 충전 한도",
                    subtitle: "시스템 설정의 Charge Limit가 충전 상한을 직접 유지합니다.",
                    icon: "battery.75percent",
                    tint: BatteryGuardPalette.info
                )

                StatusPill(
                    title: controller.nativeChargeLimitStatus.summaryText,
                    tint: BatteryGuardPalette.info,
                    icon: "checkmark.circle.fill"
                )

                Text("충전 한도를 변경하려면 macOS 시스템 설정 > 배터리에서 Charge Limit를 조절하세요.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var batteryGuardChargeLimitCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    "충전 한도",
                    subtitle: "20%에서 100% 사이, 5% 단위로 조절합니다.",
                    icon: "battery.75percent",
                    tint: BatteryGuardPalette.accent
                )

                HStack(spacing: 14) {
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

                    Text("\(controller.displayedChargeLimit)%")
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(BatteryGuardPalette.accent)
                        .frame(width: 56, alignment: .trailing)
                        .contentTransition(.numericText())
                }

                if let denial = controller.chargeLimitAvailability.denialReason {
                    StatusNotice(message: denial, kind: .info)
                }

                ChargeRecoveryStatusView(
                    controller: controller,
                    presentation: controller.batteryPresentation
                )
            }
        }
    }

    private var controlOwnershipCard: some View {
        let ownership = controller.batteryPresentation.controlOwnership
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "충전 제어 소유권",
                    subtitle: "macOS와 BatteryGuard 중 하나만 충전을 제어해야 합니다.",
                    icon: ownership.icon,
                    tint: ownership.tone.presentationTint
                )

                StatusPill(
                    title: ownership.title,
                    tint: ownership.tone.presentationTint,
                    icon: ownership.icon
                )

                Text("BatteryGuard의 Maintain, Top Up, Discharge, Heat Protection과 macOS Charge Limit를 동시에 사용하지 마세요. 단순 충전 제한만 필요하면 BatteryGuard 제어를 끄고 macOS 배터리 설정에서 Charge Limit를 사용하세요. macOS Charge Limit는 Tahoe 26.4 이상 Apple Silicon Mac에서 제공됩니다.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if controller.isChargeControlUnsupported && !controller.isBatteryControlDisabled {
                    ChargeRecoveryStatusView(
                        controller: controller,
                        presentation: controller.batteryPresentation,
                        titleOverride: "SMC 충전 제어 불가"
                    )
                }

                HStack(spacing: 10) {
                    if controller.isBatteryControlDisabled {
                        if controller.isReleasedControlDrift {
                            Button("제어 해제 다시 시도") {
                                controller.disableBatteryGuardControl()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!controller.canDisableBatteryGuardControl)
                        } else {
                            Button("BatteryGuard 제어 켜기") {
                                showsEnableControlConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(
                                !controller.isReady
                                    || controller.isCommandPending
                                    || controller.isChargeControlUnsupported
                            )
                            .help(
                                controller.controlCapabilities.chargeControl.unsupportedReason
                                    ?? "BatteryGuard 충전 제어를 켭니다."
                            )
                        }
                    } else if !controller.isChargeControlUnsupported {
                        Button("BatteryGuard 제어 끄기", role: .destructive) {
                            showsDisableControlConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(!controller.canDisableBatteryGuardControl)
                    }

                    Button("macOS 배터리 설정 열기") {
                        openBatterySettings()
                    }
                    .buttonStyle(.bordered)
                }

                if let batterySettingsOpenError {
                    StatusNotice(message: batterySettingsOpenError, kind: .critical)
                }
            }
        }
    }

    private var protectionSettings: some View {
        let controlUnavailable = controller.isBatteryControlDisabled || controller.isChargeControlUnsupported
        return VStack(spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        "잠자기 충전 보호",
                        subtitle: "Mac이 잠들기 직전에 충전 비활성을 검증합니다.",
                        icon: "moon.zzz.fill",
                        tint: BatteryGuardPalette.info
                    )

                    HStack {
                        Text("잠자기 시 동작")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker(
                            "잠자기 시 동작",
                            selection: Binding(
                                get: { settings.sleepChargingStrategy },
                                set: { controller.setSleepChargingStrategy($0) }
                            )
                        ) {
                            ForEach(SleepChargingStrategy.allCases, id: \.self) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .disabled(controlUnavailable || controller.isCommandPending)
                    }

                    if let description = controller.sleepProtectionState.userDescription {
                        StatusNotice(
                            message: description,
                            kind: sleepProtectionNoticeKind
                        )
                    }

                    Text("잠자기 직전에 Top Up과 Discharge를 중단하고 충전 비활성을 검증합니다. 실제 Mac에서 동작을 확인한 뒤 활성화하세요. 시스템이 이미 잠자기를 시작한 뒤에는 실패를 되돌릴 수 없습니다.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        "열 보호",
                        subtitle: "고온 충전이 지속되지 않도록 독립 센서로 감시합니다.",
                        icon: "thermometer.sun.fill",
                        tint: BatteryGuardPalette.warning
                    )

                    if controlUnavailable {
                        Toggle(
                            "고온 경고 배너 표시 (모니터링 전용)",
                            isOn: Binding(
                                get: { settings.monitoringHeatAlertEnabled },
                                set: { settings.monitoringHeatAlertEnabled = $0 }
                            )
                        )
                        .toggleStyle(.switch)
                    }

                    Toggle(
                        "열 보호 활성화 (충전 자동 차단)",
                        isOn: Binding(
                            get: { settings.heatProtectionEnabled },
                            set: { controller.setHeatProtectionEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(controlUnavailable)

                    if settings.heatProtectionEnabled
                        || (controlUnavailable && settings.monitoringHeatAlertEnabled) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("임계 온도")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(String(format: "%.0f°C", settings.heatProtectionThreshold))
                                    .font(.system(size: 16, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(BatteryGuardPalette.warning)
                            }
                            Slider(
                                value: Binding(
                                    get: { settings.heatProtectionThreshold },
                                    set: { settings.heatProtectionThreshold = $0 }
                                ),
                                in: 20...50,
                                step: 1
                            )
                            .accessibilityLabel("열 보호 임계 온도")
                            .accessibilityValue(String(format: "%.0f 도", settings.heatProtectionThreshold))
                        }
                    }

                    Text(
                        controlUnavailable
                            ? "모니터링 전용 모드에서는 하드웨어 충전을 직접 차단하지 않고, 안전 온도가 임계값을 넘으면 앱 내 경고 배너만 표시합니다."
                            : "배터리 온도가 임계값을 초과하면 자동으로 충전을 중단합니다. 2°C 히스테리시스를 적용해 짧은 간격의 반복 전환을 막습니다."
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 14) {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        "앱 시작",
                        subtitle: "로그인 시 앱 자동 실행을 설정합니다.",
                        icon: "power",
                        tint: BatteryGuardPalette.accent
                    )
                    Toggle(
                        "로그인 시 자동 시작",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    Text(launchAtLoginDescription)
                        .font(.system(size: 11.5))
                        .foregroundStyle(settings.launchAtLoginState == .requiresApproval ? BatteryGuardPalette.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = settings.launchAtLoginError {
                        StatusNotice(message: error, kind: .critical)
                    }
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        "MagSafe LED",
                        subtitle: "MagSafe 3 케이블 표시등으로 충전 상태를 표시합니다.",
                        icon: "lightbulb.led.fill",
                        tint: BatteryGuardPalette.neutralInk
                    )
                    Toggle(
                        "MagSafe LED 제어",
                        isOn: Binding(
                            get: { settings.controlMagSafeLED },
                            set: { controller.setLEDControlEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(controller.isBatteryControlDisabled || controller.isChargeControlUnsupported)
                    Text("초록(한도 도달), 주황(충전 중), 점멸(방전 중). MagSafe 3 모델에서만 작동합니다.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(
                        "진단",
                        subtitle: "문제가 생기면 최근 동작 기록을 확인할 수 있습니다.",
                        icon: "doc.text.magnifyingglass",
                        tint: BatteryGuardPalette.neutralInk
                    )
                    Button {
                        Task { await revealDiagnosticLog() }
                    } label: {
                        Label("진단 로그 보기", systemImage: "folder")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    if let diagnosticLogError {
                        StatusNotice(message: diagnosticLogError, kind: .critical)
                    }
                    if let fileURL = DiagnosticLog.shared.fileURL {
                        Text(fileURL.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var sleepProtectionNoticeKind: StatusNotice.Kind {
        if case .unavailable = controller.sleepProtectionState { return .critical }
        return .info
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

    private func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
              NSWorkspace.shared.open(url) else {
            batterySettingsOpenError = "macOS 배터리 설정을 열지 못했습니다. 시스템 설정에서 배터리를 직접 여세요."
            return
        }
        batterySettingsOpenError = nil
    }

    @MainActor
    private func revealDiagnosticLog() async {
        do {
            let fileURL = try await DiagnosticLog.shared.prepareForViewing()
            let observationURL = try await DiagnosticLog.powerObservations.prepareForViewing()
            diagnosticLogError = nil
            NSWorkspace.shared.activateFileViewerSelecting([fileURL, observationURL])
        } catch {
            diagnosticLogError = error.localizedDescription
        }
    }
}
