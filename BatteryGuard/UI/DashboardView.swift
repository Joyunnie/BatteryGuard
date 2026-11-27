import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var controller: ChargeController
    @EnvironmentObject private var monitor: BatteryMonitor
    @State private var historyRecords: [BatteryHistory.ChartRecord] = []
    @State private var historyError: String?
    @State private var historyViewport = BatteryHistoryViewport(now: Date())

    private enum Layout {
        static let cardSpacing: CGFloat = 16
        static let secondaryColumnWidth: CGFloat = 316
        static let primaryColumnMinimumWidth: CGFloat = 454
        static let regularMinimumWidth = primaryColumnMinimumWidth + secondaryColumnWidth + cardSpacing
        static let summaryRowMinimumHeight: CGFloat = 240
        static let detailRowMinimumHeight: CGFloat = 272
    }

    private var showsMonitoringSummaryCard: Bool {
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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    criticalContext

                    ViewThatFits(in: .horizontal) {
                        regularDashboardGrid
                        compactDashboardStack
                    }
                }
                .padding(24)
            }
        }
        .tint(BatteryGuardPalette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor.requestPresentationRefresh()
            controller.refreshNativeChargeLimit()
        }
        .task { await refreshHistory() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task { await refreshHistory() }
        }
    }

    private var regularDashboardGrid: some View {
        Grid(horizontalSpacing: Layout.cardSpacing, verticalSpacing: Layout.cardSpacing) {
            GridRow(alignment: .top) {
                batteryHero
                    .frame(
                        minWidth: Layout.primaryColumnMinimumWidth,
                        maxWidth: .infinity,
                        minHeight: Layout.summaryRowMinimumHeight,
                        maxHeight: .infinity
                    )
                chargeControlCard
                    .frame(width: Layout.secondaryColumnWidth)
                    .frame(
                        minHeight: Layout.summaryRowMinimumHeight,
                        maxHeight: .infinity
                    )
            }

            GridRow(alignment: .top) {
                chargeHistoryCard
                    .frame(
                        minWidth: Layout.primaryColumnMinimumWidth,
                        maxWidth: .infinity,
                        minHeight: Layout.detailRowMinimumHeight,
                        maxHeight: .infinity
                    )
                batteryDetailsCard
                    .frame(width: Layout.secondaryColumnWidth)
                    .frame(
                        minHeight: Layout.detailRowMinimumHeight,
                        maxHeight: .infinity
                    )
            }
        }
        .frame(minWidth: Layout.regularMinimumWidth, maxWidth: .infinity, alignment: .leading)
    }

    private var compactDashboardStack: some View {
        VStack(spacing: Layout.cardSpacing) {
            batteryHero
                .frame(maxWidth: .infinity, minHeight: Layout.summaryRowMinimumHeight)
            chargeControlCard
                .frame(maxWidth: .infinity, minHeight: Layout.summaryRowMinimumHeight)
            chargeHistoryCard
                .frame(maxWidth: .infinity, minHeight: Layout.detailRowMinimumHeight)
            batteryDetailsCard
                .frame(maxWidth: .infinity, minHeight: Layout.detailRowMinimumHeight)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BatteryGuard")
                    .font(.system(size: 24, weight: .bold))
                Text("배터리 충전 상태, 안전 온도, 7일 이력을 확인합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(
                title: controller.batteryPresentation.statusTitle,
                tint: controller.batteryPresentation.tone.presentationTint,
                icon: controller.batteryPresentation.statusIcon
            )
        }
    }

    @ViewBuilder
    private var criticalContext: some View {
        let showsRecoveryBanner = !showsUnsupportedControlCard
            && (controller.hasExternalControlDrift
                || controller.manualInterventionRecoveryDescription != nil)
        let showsIssueNotice = !showsRecoveryBanner && !showsUnsupportedControlCard && controller.issues.first != nil
        let showsHeatWarning = controller.monitoringHeatWarningMessage != nil

        if showsRecoveryBanner || showsIssueNotice || showsHeatWarning {
            VStack(alignment: .leading, spacing: 10) {
                if showsRecoveryBanner {
                    ChargeRecoveryStatusView(
                        controller: controller,
                        presentation: controller.batteryPresentation
                    )
                } else if showsIssueNotice, let issue = controller.issues.first {
                    StatusNotice(
                        message: issue.message,
                        kind: issue.severity == .critical ? .critical : .warning
                    )
                }
                if let heatWarning = controller.monitoringHeatWarningMessage {
                    StatusNotice(message: heatWarning, kind: .warning)
                }
            }
        }
    }

    private var batteryHero: some View {
        SurfaceCard(fillsAvailableHeight: true) {
            if let info = monitor.batteryInfo {
                HStack(spacing: 24) {
                    BatteryChargeRing(
                        charge: info.currentCharge,
                        tint: controller.batteryPresentation.tone.presentationTint
                    )
                    .frame(width: 146, height: 146)

                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.batteryPresentation.eyebrow)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(controller.batteryPresentation.tone.presentationTint)
                            Text(controller.batteryPresentation.headline)
                                .font(.system(size: 19, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = controller.batteryPresentation.activityDetail {
                                Text(detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()
                            .overlay(BatteryGuardPalette.borderSubtle)

                        VStack(spacing: 8) {
                            MetricRow(
                                icon: "thermometer.medium",
                                label: "안전 온도",
                                value: controller.safetyTemperatureSnapshot.displayValue,
                                tint: controller.monitoringHeatWarningMessage != nil
                                    ? BatteryGuardPalette.warning
                                    : BatteryGuardPalette.neutralInk
                            )
                            MetricRow(
                                icon: "waveform.path",
                                label: "전류",
                                value: BatteryDisplay.amperage(info.amperage)
                            )
                            MetricRow(
                                icon: controller.batteryPresentation.powerIcon,
                                label: "전원",
                                value: controller.batteryPresentation.powerLabel,
                                tint: controller.batteryPresentation.tone.presentationTint
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "battery.0percent")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("배터리 정보를 읽을 수 없습니다")
                        .font(.system(size: 15, weight: .semibold))
                    Text("연결 상태와 진단 로그를 확인해 주세요.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var chargeControlCard: some View {
        if showsMonitoringSummaryCard {
            monitoringControlSummaryCard
        } else if showsUnsupportedControlCard {
            unsupportedControlSummaryCard
        } else {
            activeChargeControlCard
        }
    }

    private var monitoringControlSummaryCard: some View {
        SurfaceCard(fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "macOS 충전 제어",
                    subtitle: "BatteryGuard는 모니터링과 7일 이력에 집중합니다.",
                    icon: "eye.fill",
                    tint: BatteryGuardPalette.info
                )

                StatusPill(
                    title: controller.nativeChargeLimitStatus.summaryText,
                    tint: BatteryGuardPalette.info,
                    icon: "battery.75percent"
                )

                VStack(alignment: .leading, spacing: 7) {
                    Label("충전 한도는 macOS 배터리 설정이 잠자기 구간까지 직접 유지합니다.", systemImage: "checkmark.circle.fill")
                    Label("실시간 전력, 안전 온도, 7일 충전 이력을 계속 기록합니다.", systemImage: "chart.xyaxis.line")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("macOS 배터리 설정 열기", systemImage: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(BatteryGuardPalette.accent)
            }
        }
    }

    private var unsupportedControlSummaryCard: some View {
        SurfaceCard(fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "SMC 충전 제어 불가",
                    subtitle: "현재 macOS에서 외부 SMC 충전 제한을 지원하지 않습니다.",
                    icon: "exclamationmark.triangle.fill",
                    tint: BatteryGuardPalette.warning
                )

                if let detail = controller.manualInterventionRecoveryDescription {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Button {
                        controller.disableBatteryGuardControl()
                    } label: {
                        Label("모니터링 전용으로 전환", systemImage: "eye")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!controller.canDisableBatteryGuardControl)

                    Button {
                        Task { await controller.refreshManualRecoveryStatus() }
                    } label: {
                        Label(controller.manualRecoveryRefreshTitle, systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!controller.manualRecoveryRefreshAvailability.isAllowed)
                }
            }
        }
    }

    private var activeChargeControlCard: some View {
        SurfaceCard(fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    "충전 제어",
                    subtitle: "평소 유지할 배터리 범위를 설정합니다.",
                    icon: "slider.horizontal.3",
                    tint: BatteryGuardPalette.accent
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("충전 한도")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(controller.displayedChargeLimit)%")
                            .font(.system(size: 22, weight: .bold))
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

                HStack(spacing: 8) {
                    chargeActionButton(
                        title: controller.isTopUpActive ? "추가 충전 취소" : "추가 충전",
                        icon: controller.isTopUpActive ? "xmark" : "arrow.up.to.line",
                        isPrimary: true,
                        availability: controller.topUpAvailability
                    ) {
                        controller.isTopUpActive ? controller.cancelTopUp() : controller.startTopUp()
                    }

                    chargeActionButton(
                        title: controller.isDischarging ? "방전 중지" : "방전 시작",
                        icon: controller.isDischarging ? "stop.fill" : "arrow.down.to.line",
                        isPrimary: controller.isDischarging,
                        availability: controller.dischargeAvailability
                    ) {
                        controller.isDischarging ? controller.stopDischarge() : controller.startDischarge()
                    }
                }

                if let denial = primaryAvailabilityDenial {
                    StatusNotice(message: denial, kind: .info)
                }
            }
        }
    }

    @ViewBuilder
    private func chargeActionButton(
        title: String,
        icon: String,
        isPrimary: Bool,
        availability: ChargeActionAvailability,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!availability.isAllowed)
        .help(availability.helpText(fallback: title))

        if isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var primaryAvailabilityDenial: String? {
        controller.chargeLimitAvailability.denialReason
            ?? controller.topUpAvailability.denialReason
            ?? controller.dischargeAvailability.denialReason
    }

    private var batteryDetailsCard: some View {
        SurfaceCard(fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "배터리 컨디션",
                    subtitle: "수명과 전기적 상태를 함께 봅니다.",
                    icon: "heart.fill",
                    tint: BatteryGuardPalette.success
                )

                if let info = monitor.batteryInfo {
                    HStack(spacing: 14) {
                        HealthGauge(percent: info.healthPercent)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("배터리 건강도")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Text(info.healthPercent.map { String(format: "%.1f%%", $0) } ?? "알 수 없음")
                                .font(.system(size: 19, weight: .bold))
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)

                    Divider()
                        .overlay(BatteryGuardPalette.borderSubtle)

                    VStack(spacing: 8) {
                        MetricRow(
                            icon: "arrow.2.circlepath",
                            label: "사이클",
                            value: BatteryDisplay.measurement(info.cycleCount)
                        )
                        MetricRow(
                            icon: "cube.box",
                            label: "용량",
                            value: BatteryDisplay.capacity(maximum: info.maxCapacity, design: info.designCapacity)
                        )
                        MetricRow(
                            icon: "bolt.batteryblock",
                            label: "전압",
                            value: BatteryDisplay.measurement(info.voltage, unit: "mV")
                        )
                        MetricRow(
                            icon: "number",
                            label: "시리얼",
                            value: info.serialNumber ?? "알 수 없음"
                        )
                    }
                } else {
                    Text("컨디션 데이터가 아직 없습니다.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: .infinity)
                }
            }
        }
    }

    private var chargeHistoryCard: some View {
        SurfaceCard(fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    "7일 충전 흐름",
                    subtitle: "최근 하루를 보고, 왼쪽으로 스크롤해 이전 기록을 확인합니다.",
                    icon: "chart.xyaxis.line",
                    tint: BatteryGuardPalette.accent
                )

                if let historyError {
                    StatusNotice(message: historyError, kind: .warning)
                        .frame(minHeight: 160)
                } else if historyRecords.count < 2 {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("7일 충전 이력을 수집하고 있습니다.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                } else {
                    historyChart
                }
            }
        }
    }

    private var historyChart: some View {
        let sampled = BatteryHistory.downsampleTimeline(
            historyRecords,
            domainEnd: historyViewport.domainEnd,
            interval: historyViewport.visibleInterval,
            maxPointsPerInterval: 120
        )
        return VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(sampled, id: \.timestamp) { record in
                    AreaMark(
                        x: .value("시간", record.timestamp),
                        y: .value("충전량", record.chargePercent)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                BatteryGuardPalette.accent.opacity(0.20),
                                BatteryGuardPalette.accent.opacity(0.01)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("시간", record.timestamp),
                        y: .value("충전량", record.chargePercent),
                        series: .value("종류", "충전량")
                    )
                    .foregroundStyle(BatteryGuardPalette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(sampled, id: \.timestamp) { record in
                    if let chargeLimit = record.chargeLimit {
                        LineMark(
                            x: .value("시간", record.timestamp),
                            y: .value("충전 한도", chargeLimit),
                            series: .value("종류", "충전 한도")
                        )
                        .foregroundStyle(BatteryGuardPalette.warning)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                    }
                }
            }
            .chartXScale(
                domain: historyViewport.domainEnd.addingTimeInterval(-BatteryHistory.retentionInterval)...historyViewport.domainEnd
            )
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: historyViewport.visibleInterval)
            .chartScrollPosition(x: $historyViewport.scrollPosition)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(BatteryGuardPalette.borderSubtle)
                    AxisValueLabel {
                        if let amount = value.as(Int.self) {
                            Text("\(amount)%")
                                .font(.system(size: 10))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                    AxisGridLine().foregroundStyle(BatteryGuardPalette.borderSubtle)
                    if let timestamp = value.as(Date.self) {
                        AxisValueLabel {
                            if Calendar.current.component(.hour, from: timestamp) == 0 {
                                Text(timestamp, format: .dateTime.month(.defaultDigits).day())
                                    .font(.system(size: 10))
                            } else {
                                Text(timestamp, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 186)

            HStack(spacing: 16) {
                chartLegend(title: "충전량", color: BatteryGuardPalette.accent, dashed: false)
                if sampled.contains(where: { $0.chargeLimit != nil }) {
                    chartLegend(title: "충전 한도", color: BatteryGuardPalette.warning, dashed: true)
                }
            }
        }
    }

    private func chartLegend(title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            StrokeLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                .frame(width: 16, height: 3)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func refreshHistory() async {
        let history = BatteryHistory.shared
        if case .failed = history.readiness {
            history.retryLoad()
        }
        let records = await history.loadRecentHistory()
        historyViewport.refresh(now: Date())
        historyRecords = records
        historyError = history.visibleError
    }
}

private struct BatteryChargeRing: View {
    let charge: Int
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: 11)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(charge, 0), 100)) / 100)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(charge)")
                    .font(.system(size: 38, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("현재 충전량")
        .accessibilityValue("\(charge) 퍼센트")
    }
}

private struct HealthGauge: View {
    let percent: Double?

    private var normalized: Double {
        min(max((percent ?? 0) / 100, 0), 1)
    }

    private var tint: Color {
        guard let percent else { return BatteryGuardPalette.neutralInk }
        if percent >= 90 { return BatteryGuardPalette.success }
        if percent >= 80 { return BatteryGuardPalette.warning }
        return BatteryGuardPalette.danger
    }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.14), lineWidth: 6.5)
            Circle()
                .trim(from: 0, to: normalized)
                .stroke(tint, style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: percent == nil ? "questionmark" : "heart.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }
}

private struct StrokeLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
