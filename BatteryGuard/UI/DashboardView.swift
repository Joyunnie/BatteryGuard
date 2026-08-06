// DashboardView.swift

import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var controller: ChargeController
    @EnvironmentObject var monitor: BatteryMonitor
    @EnvironmentObject var settings: UserSettings
    @State private var historyRecords: [BatteryHistory.ChartRecord] = []
    @State private var historyError: String?

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
        .task {
            await refreshHistory()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task { await refreshHistory() }
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
                        DetailRow(icon: "thermometer", label: "온도", value: info.temperature.map { String(format: "%.1f°C", $0) } ?? "알 수 없음")
                        DetailRow(icon: "waveform.path", label: "전류", value: BatteryDisplay.amperage(info.amperage))
                        DetailRow(icon: "bolt.batteryblock", label: "전압", value: BatteryDisplay.measurement(info.voltage, unit: "mV"))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(icon: "heart.fill", label: "건강도", value: info.healthPercent.map { String(format: "%.1f%%", $0) } ?? "알 수 없음")
                        DetailRow(icon: "arrow.2.circlepath", label: "사이클", value: BatteryDisplay.measurement(info.cycleCount))
                        DetailRow(icon: "cube.box", label: "용량", value: BatteryDisplay.capacity(maximum: info.maxCapacity, design: info.designCapacity))
                        DetailRow(icon: "number", label: "시리얼", value: info.serialNumber ?? "알 수 없음")
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
                        Text("충전 한도")
                        Spacer()
                        Text("\(controller.displayedChargeLimit)%")
                            .font(.system(.body, design: .monospaced))
                            .bold()
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
                            controller.isTopUpActive ? "추가 충전 취소" : "추가 충전",
                            systemImage: "arrow.up.to.line"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(
                        !controller.isReady ||
                        controller.isCommandPending ||
                        controller.isChargeLimitPending ||
                        controller.isHeatProtectionBlockingControls ||
                        controller.isDischarging
                    )

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
                    .disabled(
                        !controller.isReady ||
                        controller.isCommandPending ||
                        controller.isChargeLimitPending ||
                        controller.isHeatProtectionBlockingControls ||
                        controller.isTopUpActive
                    )
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
                    if let healthPercent = info.healthPercent {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: CGFloat(healthPercent / 100.0))
                                .stroke(healthColor(healthPercent), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack {
                                Text(String(format: "%.1f", healthPercent))
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                Text("%")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 100, height: 100)
                    } else {
                        Text("건강도 알 수 없음")
                            .foregroundColor(.secondary)
                            .frame(width: 100, height: 100)
                    }

                    Text("사이클 카운트: \(BatteryDisplay.measurement(info.cycleCount))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text("설계 용량: \(BatteryDisplay.measurement(info.designCapacity, unit: "mAh"))")
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
            if let error = historyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if historyRecords.count < 2 {
                Text("데이터 수집 중...")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let sampled = BatteryHistory.downsample(historyRecords, maxPoints: 200)
                VStack(alignment: .leading, spacing: 4) {
                    Chart {
                        ForEach(sampled, id: \.timestamp) { record in
                            LineMark(
                                x: .value("시간", record.timestamp),
                                y: .value("%", record.chargePercent),
                                series: .value("종류", "충전 %")
                            )
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        ForEach(sampled, id: \.timestamp) { record in
                            LineMark(
                                x: .value("시간", record.timestamp),
                                y: .value("%", record.chargeLimit),
                                series: .value("종류", "충전 한도")
                            )
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(values: [0, 25, 50, 75, 100]) { value in
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

    @MainActor
    private func refreshHistory() async {
        let history = BatteryHistory.shared
        historyRecords = await history.loadLast24Hours()
        historyError = history.visibleError
    }

    private func healthColor(_ percent: Double) -> Color {
        if percent >= 90 { return .green }
        if percent >= 80 { return .orange }
        return .red
    }
}

// MARK: - Shared Sub-views

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

/// Legend dashed-line shape
private struct StrokeLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
