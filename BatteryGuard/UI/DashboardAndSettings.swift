// DashboardAndSettings.swift
// 배터리 상세 정보 대시보드 + 설정 창

import SwiftUI
import Charts

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var controller: ChargeController
    @EnvironmentObject var monitor: BatteryMonitor
    @EnvironmentObject var settings: UserSettings
    @State private var historyRecords: [BatteryHistory.ChartRecord] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                batteryStatusCard

                HStack(spacing: 16) {
                    chargeControlCard
                    healthCard
                }

                chargeHistoryCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { historyRecords = BatteryHistory.shared.fetchLast24Hours() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            historyRecords = BatteryHistory.shared.fetchLast24Hours()
        }
    }

    // MARK: - Battery Status Card
    private var batteryStatusCard: some View {
        GroupBox {
            if let info = monitor.batteryInfo {
                HStack(spacing: 30) {
                    VStack {
                        Text("\(info.currentCharge)")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Divider().frame(height: 80)

                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(icon: "bolt.fill", label: "상태", value: controller.currentState.rawValue)
                        DetailRow(icon: "thermometer", label: "온도", value: String(format: "%.1f°C", info.temperature))
                        DetailRow(icon: "waveform.path", label: "전류", value: "\(info.amperage) mA")
                        DetailRow(icon: "bolt.batteryblock", label: "전압", value: "\(info.voltage) mV")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(icon: "heart.fill", label: "건강도", value: String(format: "%.1f%%", info.healthPercent))
                        DetailRow(icon: "arrow.2.circlepath", label: "사이클", value: "\(info.cycleCount)")
                        DetailRow(icon: "cube.box", label: "용량", value: "\(info.maxCapacity)/\(info.designCapacity) mAh")
                        DetailRow(icon: "number", label: "시리얼", value: info.serialNumber)
                    }
                }
                .padding()
            } else {
                Text("배터리 정보를 읽을 수 없습니다")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Charge Control Card
    private var chargeControlCard: some View {
        GroupBox("충전 제어") {
            VStack(spacing: 16) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Charge Limit")
                        Spacer()
                        Text("\(settings.chargeLimit)%")
                            .font(.system(.body, design: .monospaced))
                            .bold()
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

                Divider()

                HStack(spacing: 12) {
                    Button(action: {
                        if controller.isTopUpActive {
                            controller.cancelTopUp()
                        } else {
                            controller.startTopUp()
                        }
                    }) {
                        Label(
                            controller.isTopUpActive ? "Top Up 취소" : "Top Up",
                            systemImage: "arrow.up.to.line"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)

                    Button(action: {
                        if controller.isDischarging {
                            controller.stopDischarge()
                        } else {
                            controller.startDischarge()
                        }
                    }) {
                        Label(
                            controller.isDischarging ? "방전 중지" : "방전 시작",
                            systemImage: "arrow.down.to.line"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
            .padding()
        }
    }

    // MARK: - Health Card
    private var healthCard: some View {
        GroupBox("배터리 건강") {
            VStack(spacing: 12) {
                if let info = monitor.batteryInfo {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(info.healthPercent / 100.0))
                            .stroke(healthColor(info.healthPercent), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack {
                            Text(String(format: "%.1f", info.healthPercent))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            Text("%")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 100, height: 100)

                    Text("사이클 카운트: \(info.cycleCount)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text("설계 용량: \(info.designCapacity) mAh")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Charge History Chart
    private var chargeHistoryCard: some View {
        GroupBox("충전 이력 (24시간)") {
            if historyRecords.count < 2 {
                Text("데이터 수집 중...")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let allValues = historyRecords.flatMap { [$0.chargePercent, $0.chargeLimit] }
                let dataMin = allValues.min() ?? 0
                let dataMax = allValues.max() ?? 100
                let range = max(dataMax - dataMin, 20)
                let yMin = max(0, dataMin - 5)
                let yMax = min(100, yMin + range + 10)

                VStack(alignment: .leading, spacing: 4) {
                    Chart {
                        ForEach(historyRecords, id: \.timestamp) { record in
                            LineMark(
                                x: .value("시간", record.timestamp),
                                y: .value("%", record.chargePercent),
                                series: .value("종류", "충전 %")
                            )
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        ForEach(historyRecords, id: \.timestamp) { record in
                            LineMark(
                                x: .value("시간", record.timestamp),
                                y: .value("%", record.chargeLimit),
                                series: .value("종류", "충전 한도")
                            )
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        }
                    }
                    .chartYScale(domain: yMin...yMax)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = value.as(Int.self) {
                                    Text("\(v)%")
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 1)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: 150)

                    // 범례
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(.blue)
                                .frame(width: 14, height: 2)
                            Text("충전 %")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            StrokeLine()
                                .stroke(.gray.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                .frame(width: 14, height: 2)
                            Text("충전 한도")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func healthColor(_ percent: Double) -> Color {
        if percent >= 90 { return .green }
        if percent >= 80 { return .orange }
        return .red
    }
}

// MARK: - Sub-views

struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundColor(.accentColor)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

/// 범례용 직선 Shape
private struct StrokeLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Settings View

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
                    // #9: controller.setChargeLimit()로 applyMaintain도 호출
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
