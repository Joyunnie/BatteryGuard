import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var controller: ChargeController
    @EnvironmentObject private var monitor: BatteryMonitor
    @State private var historyRecords: [BatteryHistory.ChartRecord] = []
    @State private var historyError: String?
    @State private var historyViewport = BatteryHistoryViewport(now: Date())

    private enum Layout {
        static let cardSpacing: CGFloat = 18
        static let secondaryColumnWidth: CGFloat = 310
        static let primaryColumnMinimumWidth: CGFloat = 460
        static let regularMinimumWidth = primaryColumnMinimumWidth + secondaryColumnWidth + cardSpacing
        static let summaryRowMinimumHeight: CGFloat = 244
        static let detailRowMinimumHeight: CGFloat = 270
    }

    var body: some View {
        ZStack {
            PastelCanvas()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    criticalContext

                    ViewThatFits(in: .horizontal) {
                        regularDashboardGrid
                        compactDashboardStack
                    }
                }
                .padding(28)
            }
        }
        .tint(BatteryGuardPalette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.requestPresentationRefresh() }
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
            VStack(alignment: .leading, spacing: 5) {
                Text("BatteryGuard")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("충전 상태와 보호 기능을 한눈에 확인하세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            PastelStatusPill(
                title: controller.primaryChargeStatusTitle,
                tint: controller.currentState.presentationTint,
                icon: controller.currentState.presentationIcon
            )
        }
    }

    @ViewBuilder
    private var criticalContext: some View {
        if controller.hasExternalControlDrift
            || controller.manualInterventionRecoveryDescription != nil {
            ChargeRecoveryStatusView(controller: controller)
        } else if let issue = controller.issues.first {
            PastelNotice(
                message: issue.message,
                kind: issue.severity == .critical ? .critical : .warning
            )
        }
    }

    private var batteryHero: some View {
        PastelCard(tint: controller.currentState.presentationTint, fillsAvailableHeight: true) {
            if let info = monitor.batteryInfo {
                HStack(spacing: 26) {
                    BatteryChargeRing(
                        charge: info.currentCharge,
                        tint: controller.currentState.presentationTint
                    )
                    .frame(width: 150, height: 150)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(statusEyebrow(for: info))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(controller.currentState.presentationTint)
                            Text(statusHeadline)
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 8) {
                            PastelMetricRow(
                                icon: "thermometer.medium",
                                label: "안전 온도",
                                value: controller.safetyTemperatureSnapshot.displayValue,
                                tint: BatteryGuardPalette.peachInk
                            )
                            PastelMetricRow(
                                icon: "waveform.path",
                                label: "전류",
                                value: BatteryDisplay.amperage(info.amperage),
                                tint: BatteryGuardPalette.skyInk
                            )
                            PastelMetricRow(
                                icon: info.isPluggedIn ? "powerplug.fill" : "powerplug",
                                label: "전원",
                                value: info.isPluggedIn ? "연결됨" : "연결 안 됨",
                                tint: BatteryGuardPalette.mintInk
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "battery.0percent")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(BatteryGuardPalette.lavenderInk)
                    Text("배터리 정보를 읽을 수 없습니다")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("연결 상태와 진단 로그를 확인해 주세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
            }
        }
    }

    private var chargeControlCard: some View {
        PastelCard(tint: BatteryGuardPalette.lavender, fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 18) {
                PastelSectionHeader(
                    "충전 제어",
                    subtitle: "평소 유지할 배터리 범위를 정합니다.",
                    icon: "slider.horizontal.3",
                    tint: BatteryGuardPalette.accent
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("충전 한도")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(controller.displayedChargeLimit)%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
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

                HStack(spacing: 10) {
                    chargeActionButton(
                        title: controller.isTopUpActive ? "추가 충전 취소" : "추가 충전",
                        icon: controller.isTopUpActive ? "xmark" : "arrow.up.to.line",
                        tint: BatteryGuardPalette.accent,
                        availability: controller.topUpAvailability
                    ) {
                        controller.isTopUpActive ? controller.cancelTopUp() : controller.startTopUp()
                    }

                    chargeActionButton(
                        title: controller.isDischarging ? "방전 중지" : "방전 시작",
                        icon: controller.isDischarging ? "stop.fill" : "arrow.down.to.line",
                        tint: BatteryGuardPalette.skyInk,
                        availability: controller.dischargeAvailability
                    ) {
                        controller.isDischarging ? controller.stopDischarge() : controller.startDischarge()
                    }
                }

                if let denial = primaryAvailabilityDenial {
                    PastelNotice(message: denial, kind: .info)
                }
            }
        }
    }

    private func chargeActionButton(
        title: String,
        icon: String,
        tint: Color,
        availability: ChargeActionAvailability,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
        .disabled(!availability.isAllowed)
        .help(availability.helpText(fallback: title))
    }

    private var primaryAvailabilityDenial: String? {
        controller.chargeLimitAvailability.denialReason
            ?? controller.topUpAvailability.denialReason
            ?? controller.dischargeAvailability.denialReason
    }

    private var batteryDetailsCard: some View {
        PastelCard(tint: BatteryGuardPalette.mint, fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                PastelSectionHeader(
                    "배터리 컨디션",
                    subtitle: "수명과 전기적 상태를 함께 봅니다.",
                    icon: "heart.fill",
                    tint: BatteryGuardPalette.success
                )

                if let info = monitor.batteryInfo {
                    HStack(spacing: 14) {
                        HealthGauge(percent: info.healthPercent)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("배터리 건강도")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(info.healthPercent.map { String(format: "%.1f%%", $0) } ?? "알 수 없음")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                        }
                    }
                    .accessibilityElement(children: .combine)

                    Divider().opacity(0.45)

                    VStack(spacing: 9) {
                        PastelMetricRow(
                            icon: "arrow.2.circlepath",
                            label: "사이클",
                            value: BatteryDisplay.measurement(info.cycleCount),
                            tint: BatteryGuardPalette.lavenderInk
                        )
                        PastelMetricRow(
                            icon: "cube.box",
                            label: "용량",
                            value: BatteryDisplay.capacity(maximum: info.maxCapacity, design: info.designCapacity),
                            tint: BatteryGuardPalette.mintInk
                        )
                        PastelMetricRow(
                            icon: "bolt.batteryblock",
                            label: "전압",
                            value: BatteryDisplay.measurement(info.voltage, unit: "mV"),
                            tint: BatteryGuardPalette.butterInk
                        )
                        PastelMetricRow(
                            icon: "number",
                            label: "시리얼",
                            value: info.serialNumber ?? "알 수 없음",
                            tint: BatteryGuardPalette.peachInk
                        )
                    }
                } else {
                    Text("컨디션 데이터가 아직 없습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: .infinity)
                }
            }
        }
    }

    private var chargeHistoryCard: some View {
        PastelCard(tint: BatteryGuardPalette.sky, fillsAvailableHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                PastelSectionHeader(
                    "7일 충전 흐름",
                    subtitle: "최근 하루를 보고, 왼쪽으로 스크롤해 이전 기록을 확인합니다.",
                    icon: "chart.xyaxis.line",
                    tint: BatteryGuardPalette.accent
                )

                if let historyError {
                    PastelNotice(message: historyError, kind: .warning)
                        .frame(minHeight: 160)
                } else if historyRecords.count < 2 {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("7일 충전 이력을 모으고 있어요")
                            .font(.system(size: 11))
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
                            colors: [BatteryGuardPalette.accent.opacity(0.26), BatteryGuardPalette.accent.opacity(0.015)],
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
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(sampled, id: \.timestamp) { record in
                    LineMark(
                        x: .value("시간", record.timestamp),
                        y: .value("충전 한도", record.chargeLimit),
                        series: .value("종류", "충전 한도")
                    )
                    .foregroundStyle(BatteryGuardPalette.peachInk)
                    .lineStyle(StrokeStyle(lineWidth: 1.7, dash: [6, 4]))
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
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let amount = value.as(Int.self) {
                            Text("\(amount)%").font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.10))
                    if let timestamp = value.as(Date.self) {
                        AxisValueLabel {
                            if Calendar.current.component(.hour, from: timestamp) == 0 {
                                Text(timestamp, format: .dateTime.month(.defaultDigits).day())
                            } else {
                                Text(timestamp, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                            }
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 190)

            HStack(spacing: 18) {
                chartLegend(title: "충전량", color: BatteryGuardPalette.accent, dashed: false)
                chartLegend(title: "충전 한도", color: BatteryGuardPalette.peach, dashed: true)
            }
        }
    }

    private func chartLegend(title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            StrokeLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                .frame(width: 18, height: 3)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func statusEyebrow(for info: BatteryInfo) -> String {
        info.isPluggedIn ? "전원 연결됨" : "배터리 사용 중"
    }

    private var statusHeadline: String {
        switch controller.currentState {
        case .charging: return "한도까지 충전하고 있어요"
        case .chargingPaused:
            switch controller.mode {
            case .heatBlocked: return "고온으로 충전을 잠시 멈췄어요"
            case .sleepProtected: return "잠자기 동안 충전을 멈췄어요"
            case .controlDisabled: return "macOS가 충전 상태를 관리하고 있어요"
            case .transitioning: return "안전한 충전 상태로 전환 중이에요"
            case .externalDrift: return "외부에서 바뀐 상태를 확인해 주세요"
            default: return "설정한 범위를 지키고 있어요"
            }
        case .discharging: return "목표까지 안전하게 방전 중이에요"
        case .topUp: return "추가 충전을 진행하고 있어요"
        case .notConnected: return "배터리 전원으로 사용 중이에요"
        case .unknown: return "충전 상태를 확인해 주세요"
        }
    }

    @MainActor
    private func refreshHistory() async {
        let history = BatteryHistory.shared
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
                .stroke(tint.opacity(0.12), lineWidth: 13)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(charge, 0), 100)) / 100)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint, BatteryGuardPalette.mint],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 13, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(charge)")
                    .font(.system(size: 43, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("퍼센트")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
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
        guard let percent else { return .secondary }
        if percent >= 90 { return BatteryGuardPalette.success }
        if percent >= 80 { return BatteryGuardPalette.warning }
        return BatteryGuardPalette.danger
    }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.12), lineWidth: 7)
            Circle()
                .trim(from: 0, to: normalized)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: percent == nil ? "questionmark" : "heart.fill")
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
