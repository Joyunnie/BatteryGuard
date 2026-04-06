// DashboardAndSettings.swift
// 배터리 상세 정보 대시보드 + 설정 창

import SwiftUI

// MARK: - Dashboard View

struct DashboardView: View {
    @EnvironmentObject var controller: ChargeController
    @EnvironmentObject var monitor: BatteryMonitor
    @EnvironmentObject var settings: UserSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                batteryStatusCard

                HStack(spacing: 16) {
                    chargeControlCard
                    healthCard
                }

                calibrationCard
                chargeHistoryCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Calibration Card
    private var calibrationCard: some View {
        GroupBox("캘리브레이션") {
            VStack(spacing: 12) {
                if controller.isCalibrating {
                    HStack {
                        ProgressView(value: controller.calibrationMode.progress)
                        Text(controller.calibrationMode.currentPhase.rawValue)
                            .font(.system(size: 12))
                    }

                    Button("캘리브레이션 취소") {
                        controller.cancelCalibration()
                    }
                    .foregroundColor(.red)
                } else {
                    Text("배터리 캘리브레이션으로 잔량 표시 정확도를 복원합니다.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text("사이클: 현재 → 100% → 10% → 100% → 1시간 유지 → 복원")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button("캘리브레이션 시작") {
                        controller.startCalibration()
                    }
                    .controlSize(.large)
                }
            }
            .padding()
        }
    }

    // MARK: - Charge History
    private var chargeHistoryCard: some View {
        GroupBox("충전 이력 (24시간)") {
            if monitor.chargeHistory.isEmpty {
                Text("데이터 수집 중...")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ChargeHistoryChart(records: monitor.chargeHistory)
                    .frame(height: 150)
                    .padding()
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

struct ChargeHistoryChart: View {
    let records: [BatteryMonitor.ChargeRecord]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            Path { path in
                guard records.count > 1 else { return }

                let timeRange = records.last!.timestamp.timeIntervalSince(records.first!.timestamp)
                guard timeRange > 0 else { return }

                for (index, record) in records.enumerated() {
                    let x = CGFloat(record.timestamp.timeIntervalSince(records.first!.timestamp)) / CGFloat(timeRange) * width
                    let y = height - CGFloat(record.charge) / 100.0 * height

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)

            ForEach([0, 25, 50, 75, 100], id: \.self) { level in
                let y = height - CGFloat(level) / 100.0 * height
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)

                Text("\(level)%")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .position(x: -15, y: y)
            }
        }
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

            sailingSettings
                .tabItem { Label("Sailing", systemImage: "wind") }

            protectionSettings
                .tabItem { Label("보호", systemImage: "shield.fill") }

            appearanceSettings
                .tabItem { Label("외관", systemImage: "paintbrush") }
        }
        .frame(width: 450, height: 350)
        .padding()
    }

    private var chargeSettings: some View {
        Form {
            Section("Charge Limit") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(settings.chargeLimit) },
                            set: { settings.chargeLimit = Int($0) }
                        ),
                        in: 20...100,
                        step: 5
                    )
                    Text("\(settings.chargeLimit)%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 45)
                }
            }

            Section("Discharge") {
                Toggle("Automatic Discharge", isOn: $settings.autoDischargeEnabled)
                Text("현재 잔량이 Charge Limit보다 높을 때 자동 방전")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("Sleep") {
                Toggle("Sleep 시 충전 중지", isOn: $settings.stopChargingOnSleep)
                Text("MacBook이 sleep에 들어가기 전 충전을 일시정지합니다")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var sailingSettings: some View {
        Form {
            Section("Sailing Mode") {
                Toggle("Sailing Mode 활성화", isOn: $settings.sailingEnabled)

                if settings.sailingEnabled {
                    HStack {
                        Text("하한")
                        Slider(
                            value: Binding(
                                get: { Double(settings.sailingLowerBound) },
                                set: { settings.sailingLowerBound = Int($0) }
                            ),
                            in: 20...Double(max(20, settings.chargeLimit - 1)),
                            step: 5
                        )
                        Text("\(settings.sailingLowerBound)%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 45)
                    }

                    Text("범위: \(settings.sailingLowerBound)% ~ \(settings.chargeLimit)%")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                }
            }

            Section("설명") {
                Text("""
                Sailing Mode는 배터리를 설정 범위 내에서 자연스럽게 \
                오르내리게 합니다. 능동적으로 방전하지 않으며, \
                셀 자가 방전과 시스템 부하 초과 시의 자연 소모를 이용합니다.
                """)
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
                    HStack {
                        Text("임계 온도")
                        Slider(
                            value: $settings.heatProtectionThreshold,
                            in: 30...50,
                            step: 1
                        )
                        Text(String(format: "%.0f°C", settings.heatProtectionThreshold))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 45)
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
