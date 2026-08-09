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

        var tint: Color {
            switch self {
            case .charge: return BatteryGuardPalette.accent
            case .protection: return BatteryGuardPalette.mintInk
            case .general: return BatteryGuardPalette.peachInk
            }
        }
    }

    @EnvironmentObject private var settings: UserSettings
    @EnvironmentObject private var controller: ChargeController
    @State private var selection: Destination = .charge
    @State private var diagnosticLogError: String?
    @State private var batterySettingsOpenError: String?
    @State private var showsDisableControlConfirmation = false
    @State private var showsEnableControlConfirmation = false

    var body: some View {
        ZStack {
            PastelCanvas()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 200)

                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 1)
                    .padding(.vertical, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageHeader
                        selectedPage
                    }
                    .padding(26)
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
        .onAppear { settings.refreshLaunchAtLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BatteryGuardPalette.success)
                        .frame(width: 30, height: 30)
                        .background(BatteryGuardPalette.mint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                    Text("BatteryGuard")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text("나만의 배터리 루틴")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)

            VStack(spacing: 6) {
                ForEach(Destination.allCases) { destination in
                    sidebarButton(destination)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("BatteryGuard")
                    .font(.system(size: 10, weight: .semibold))
                Text("v\(AppMetadata.version)")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .padding(18)
    }

    private func sidebarButton(_ destination: Destination) -> some View {
        let isSelected = selection == destination
        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? destination.tint : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (isSelected ? destination.tint : Color.secondary).opacity(isSelected ? 0.14 : 0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(destination.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? destination.tint.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(destination.rawValue) 설정")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.rawValue)
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text(pageSubtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var pageSubtitle: String {
        switch selection {
        case .charge: return "충전 한도와 BatteryGuard의 제어 범위를 관리합니다."
        case .protection: return "잠자기와 고온 상황에서도 배터리를 안전하게 지킵니다."
        case .general: return "앱 시작 방식, MagSafe LED, 진단 정보를 관리합니다."
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
        VStack(spacing: 16) {
            PastelCard(tint: BatteryGuardPalette.lavender) {
                VStack(alignment: .leading, spacing: 18) {
                    PastelSectionHeader(
                        "충전 한도",
                        subtitle: "20%에서 100% 사이, 5% 단위로 조절합니다.",
                        icon: "battery.75percent",
                        tint: BatteryGuardPalette.accent
                    )

                    HStack(spacing: 16) {
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
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(BatteryGuardPalette.accent)
                            .frame(width: 60, alignment: .trailing)
                            .contentTransition(.numericText())
                    }

                    if let denial = controller.chargeLimitAvailability.denialReason {
                        PastelNotice(message: denial, kind: .info)
                    }

                    ExternalDriftStatusView(controller: controller)
                }
            }

            controlOwnershipCard

            PastelNotice(
                message: "Maintain worker는 시스템 잠자기 동안 실행되지 않습니다. 잠자기 충전 보호가 이 구간을 별도로 맡습니다.",
                kind: .info
            )
        }
    }

    private var controlOwnershipCard: some View {
        PastelCard(tint: controller.isBatteryControlDisabled ? BatteryGuardPalette.sky : BatteryGuardPalette.mint) {
            VStack(alignment: .leading, spacing: 14) {
                PastelSectionHeader(
                    "충전 제어 소유권",
                    subtitle: "macOS와 BatteryGuard 중 하나만 충전을 제어해야 합니다.",
                    icon: controller.isBatteryControlDisabled ? "eye.fill" : "checkmark.shield.fill",
                    tint: controller.isBatteryControlDisabled ? BatteryGuardPalette.sky : BatteryGuardPalette.success
                )

                PastelStatusPill(
                    title: controller.isBatteryControlDisabled
                        ? "macOS 제어, BatteryGuard 모니터링 전용"
                        : "BatteryGuard가 충전 제어 중",
                    tint: controller.isBatteryControlDisabled ? BatteryGuardPalette.sky : BatteryGuardPalette.success,
                    icon: controller.isBatteryControlDisabled ? "eye.fill" : "checkmark.shield.fill"
                )

                Text("BatteryGuard의 Maintain, Top Up, Discharge, Heat Protection과 macOS Charge Limit를 동시에 사용하지 마세요. 단순 제한만 필요하면 BatteryGuard 제어를 끈 뒤 macOS 배터리 설정에서 Charge Limit를 사용하세요. macOS Charge Limit는 Tahoe 26.4 이상 Apple Silicon Mac에서 제공됩니다.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if controller.isBatteryControlDisabled {
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
                        Button("BatteryGuard 제어 끄기", role: .destructive) {
                            showsDisableControlConfirmation = true
                        }
                        .disabled(!controller.isReady || controller.isCommandPending || controller.hasExternalControlDrift)
                    }

                    Button("macOS 배터리 설정 열기") {
                        openBatterySettings()
                    }
                }
                .buttonStyle(.bordered)

                if let batterySettingsOpenError {
                    PastelNotice(message: batterySettingsOpenError, kind: .critical)
                }
            }
        }
    }

    private var protectionSettings: some View {
        VStack(spacing: 16) {
            PastelCard(tint: BatteryGuardPalette.sky) {
                VStack(alignment: .leading, spacing: 16) {
                    PastelSectionHeader(
                        "잠자기 충전 보호",
                        subtitle: "Mac이 잠들기 직전에 충전 비활성을 검증합니다.",
                        icon: "moon.zzz.fill",
                        tint: BatteryGuardPalette.skyInk
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
                        .disabled(controller.isBatteryControlDisabled || controller.isCommandPending)
                    }

                    if let description = controller.sleepProtectionState.userDescription {
                        PastelNotice(
                            message: description,
                            kind: sleepProtectionNoticeKind
                        )
                    }

                    Text("잠자기 직전에 Top Up과 Discharge를 중단하고 충전 비활성을 검증합니다. 실제 Mac에서 동작을 확인한 뒤 활성화하세요. 시스템이 이미 잠자기를 시작한 뒤에는 실패를 되돌릴 수 없습니다.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PastelCard(tint: BatteryGuardPalette.peach) {
                VStack(alignment: .leading, spacing: 16) {
                    PastelSectionHeader(
                        "열 보호",
                        subtitle: "고온 충전이 지속되지 않도록 독립 센서로 감시합니다.",
                        icon: "thermometer.sun.fill",
                        tint: BatteryGuardPalette.peachInk
                    )

                    Toggle(
                        "열 보호 활성화",
                        isOn: Binding(
                            get: { settings.heatProtectionEnabled },
                            set: { controller.setHeatProtectionEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(controller.isBatteryControlDisabled)

                    if settings.heatProtectionEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("임계 온도")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(String(format: "%.0f°C", settings.heatProtectionThreshold))
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundStyle(BatteryGuardPalette.peachInk)
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

                    Text("배터리 온도가 임계값을 초과하면 자동으로 충전을 중단합니다. 2°C 히스테리시스를 적용해 짧은 간격의 반복 전환을 막습니다.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 16) {
            PastelCard(tint: BatteryGuardPalette.lavender) {
                VStack(alignment: .leading, spacing: 14) {
                    PastelSectionHeader(
                        "앱 시작",
                        subtitle: "필요할 때 자동으로 BatteryGuard를 준비합니다.",
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
                        .font(.system(size: 10.5))
                        .foregroundStyle(settings.launchAtLoginState == .requiresApproval ? BatteryGuardPalette.warning : .secondary)
                    if let error = settings.launchAtLoginError {
                        PastelNotice(message: error, kind: .critical)
                    }
                }
            }

            PastelCard(tint: BatteryGuardPalette.mint) {
                VStack(alignment: .leading, spacing: 14) {
                    PastelSectionHeader(
                        "MagSafe LED",
                        subtitle: "케이블의 작은 불빛으로 현재 상태를 알립니다.",
                        icon: "lightbulb.led.fill",
                        tint: BatteryGuardPalette.success
                    )
                    Toggle(
                        "MagSafe LED 제어",
                        isOn: Binding(
                            get: { settings.controlMagSafeLED },
                            set: { controller.setLEDControlEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(controller.isBatteryControlDisabled)
                    Text("초록: 한도 도달  ·  주황: 충전 중  ·  점멸: 방전 중\nMagSafe 3 모델에서만 작동합니다.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            PastelCard(tint: BatteryGuardPalette.sky) {
                VStack(alignment: .leading, spacing: 14) {
                    PastelSectionHeader(
                        "진단",
                        subtitle: "문제가 생기면 최근 동작 기록을 확인할 수 있습니다.",
                        icon: "doc.text.magnifyingglass",
                        tint: BatteryGuardPalette.skyInk
                    )
                    Button {
                        Task { await revealDiagnosticLog() }
                    } label: {
                        Label("진단 로그 보기", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    if let diagnosticLogError {
                        PastelNotice(message: diagnosticLogError, kind: .critical)
                    }
                    if let fileURL = DiagnosticLog.shared.fileURL {
                        Text(fileURL.path)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var sleepProtectionNoticeKind: PastelNotice.Kind {
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
            diagnosticLogError = nil
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } catch {
            diagnosticLogError = error.localizedDescription
        }
    }
}
