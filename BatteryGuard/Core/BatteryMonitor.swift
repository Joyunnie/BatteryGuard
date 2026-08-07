// BatteryMonitor.swift
// IOKit의 IOPMPowerSource를 통한 배터리 상태 모니터링
// SMC와 별개로, macOS 전원 관리 프레임워크에서 배터리 정보를 가져옴

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Combine

// MARK: - BatteryInfo
/// IOPMPowerSource에서 읽어오는 배터리 상태 정보
struct BatteryInfo {
    let currentCharge: Int           // 현재 충전 퍼센트 (0-100)
    let isCharging: Bool             // 충전 중 여부
    let isPluggedIn: Bool            // 전원 연결 여부
    let maxCapacity: Int?            // 최대 용량 (mAh)
    let designCapacity: Int?         // 설계 용량 (mAh)
    let cycleCount: Int?             // 충방전 사이클 수
    let temperature: Double?         // 온도 (°C), 센서 값이 없으면 nil
    let amperage: Int?               // 전류 (mA, 양수=충전, 음수=방전), 값이 없으면 nil
    let voltage: Int?                // 전압 (mV)
    let timeToFull: Int              // 완충까지 남은 시간 (분), -1이면 N/A
    let timeToEmpty: Int             // 방전까지 남은 시간 (분), -1이면 N/A
    let healthPercent: Double?       // 배터리 건강도 (%), 계산할 수 없으면 nil
    let isPresent: Bool              // 배터리 존재 여부
    let serialNumber: String?        // 배터리 시리얼 번호
}

// MARK: - BatteryMonitor
/// 배터리 상태를 주기적으로 모니터링하는 클래스
/// - IOPMPowerSource: macOS 전원 관리 프레임워크. 배터리 상태를 userspace에 노출
/// - IOServiceGetMatchingService: IOKit 레지스트리에서 AppleSmartBattery 서비스 검색
/// - 2초 간격 폴링 + IOPowerSource notification 조합
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor(runsMonitoringInfrastructure: !AppRuntime.isRunningTests)

    @Published var batteryInfo: BatteryInfo?

    private let batteryInfoProvider: (() -> BatteryInfo?)?
    private let runsMonitoringInfrastructure: Bool
    private let preventSleepHandler: ((String) -> Bool)?
    private let allowSleepHandler: (() -> Void)?
    var usesMonitoringInfrastructure: Bool { runsMonitoringInfrastructure }
    private(set) var isSleepPreventionActive = false
    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?

    init(
        batteryInfoProvider: (() -> BatteryInfo?)? = nil,
        runsMonitoringInfrastructure: Bool = true,
        preventSleepHandler: ((String) -> Bool)? = nil,
        allowSleepHandler: (() -> Void)? = nil
    ) {
        self.batteryInfoProvider = batteryInfoProvider
        self.runsMonitoringInfrastructure = runsMonitoringInfrastructure
        self.preventSleepHandler = preventSleepHandler
        self.allowSleepHandler = allowSleepHandler
    }

    // MARK: - Helper

    /// IOKit 딕셔너리에서 Bool 읽기. CFBoolean / NSNumber 모두 처리.
    private nonisolated static func readBool(_ dict: [String: Any], key: String, default defaultVal: Bool = false) -> Bool {
        if let b = dict[key] as? Bool { return b }
        if let n = dict[key] as? NSNumber { return n.boolValue }
        if let n = dict[key] as? Int { return n != 0 }
        return defaultVal
    }

    // MARK: - IOKit을 통한 배터리 정보 읽기

    /// AppleSmartBattery 서비스에서 배터리 딕셔너리 읽기
    func readBatteryInfo() -> BatteryInfo? {
        if let batteryInfoProvider { return batteryInfoProvider() }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )

        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &props,
            kCFAllocatorDefault,
            0
        )

        guard result == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        return Self.parseBatteryInfo(dict)
    }

    nonisolated static func parseBatteryInfo(_ dict: [String: Any]) -> BatteryInfo? {
        // CurrentCapacity: macOS 표시 % (0-100)
        guard let currentCharge = dict["CurrentCapacity"] as? Int,
              (0...100).contains(currentCharge) else {
            return nil
        }

        // AppleRawMaxCapacity: 실제 최대 용량 (mAh). MaxCapacity는 %라서 사용 불가.
        let rawMaxCapacity = Self.positiveMeasurement(dict["AppleRawMaxCapacity"] as? Int)
        let designCapacity = Self.positiveMeasurement(dict["DesignCapacity"] as? Int)

        let isCharging = readBool(dict, key: "IsCharging")
        let externalConnected = readBool(dict, key: "ExternalConnected")
        // ExternalConnected는 force discharge 시 CHIE에 의해 false로 보고됨.
        // ExternalChargeCapable / AppleRawExternalConnected는 물리적 연결 상태를 반영.
        let externalChargeCapable = readBool(dict, key: "ExternalChargeCapable")
        let rawExternalConnected = readBool(dict, key: "AppleRawExternalConnected")
        let cycleCount = Self.nonnegativeMeasurement(dict["CycleCount"] as? Int)

        // Temperature: 데시켈빈 (K × 10). 예: 2969 → 296.9K → 23.75°C
        let rawTemp = dict["Temperature"] as? Int
        let tempCelsius = rawTemp.flatMap {
            Self.validatedTemperature(Double($0) / 10.0 - 273.15)
        }

        // Amperage is documented as mA, but IOKit can bridge a negative value
        // through an unsigned CFNumber representation. Reject implausible
        // values instead of displaying a wrapped integer as a real current.
        let amperage = Self.normalizedAmperage(dict["Amperage"] as? NSNumber)

        let voltage = Self.positiveMeasurement(dict["Voltage"] as? Int)
        let timeToFull = dict["AvgTimeToFull"] as? Int ?? -1
        let timeToEmpty = dict["AvgTimeToEmpty"] as? Int ?? -1
        let batteryPresent = readBool(dict, key: "BatteryInstalled", default: true)
        let serialNumber = (dict["Serial"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // 건강도: AppleRawMaxCapacity / DesignCapacity (둘 다 mAh)
        let health: Double?
        if let designCapacity, let rawMaxCapacity {
            health = (Double(rawMaxCapacity) / Double(designCapacity)) * 100.0
        } else {
            health = nil
        }

        // ExternalConnected 외에 ExternalChargeCapable / AppleRawExternalConnected로 보완
        let pluggedIn = externalConnected || externalChargeCapable || rawExternalConnected || isCharging

        return BatteryInfo(
            currentCharge: currentCharge,
            isCharging: isCharging,
            isPluggedIn: pluggedIn,
            maxCapacity: rawMaxCapacity,
            designCapacity: designCapacity,
            cycleCount: cycleCount,
            temperature: tempCelsius,
            amperage: amperage,
            voltage: voltage,
            timeToFull: isCharging ? (timeToFull == 65535 ? -1 : timeToFull) : -1,
            timeToEmpty: !isCharging ? (timeToEmpty == 65535 ? -1 : timeToEmpty) : -1,
            healthPercent: health,
            isPresent: batteryPresent,
            serialNumber: serialNumber
        )
    }

    nonisolated static func normalizedAmperage(_ number: NSNumber?) -> Int? {
        guard let number else { return nil }
        let plausibleRange: ClosedRange<Int64> = -50_000...50_000
        let signedValue = number.int64Value
        if plausibleRange.contains(signedValue) { return Int(signedValue) }

        let unsignedValue = number.uint64Value
        let bridgedType = String(cString: number.objCType)
        let recovered: Int64?
        switch bridgedType {
        case "S":
            recovered = Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: unsignedValue)))
        case "I", "L":
            recovered = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: unsignedValue)))
        case "Q":
            recovered = Int64(bitPattern: unsignedValue)
        default:
            recovered = nil
        }
        guard let recovered, plausibleRange.contains(recovered) else { return nil }
        return Int(recovered)
    }

    nonisolated static func validatedTemperature(_ value: Double) -> Double? {
        guard value.isFinite, (-20.0...100.0).contains(value) else { return nil }
        return value
    }

    private nonisolated static func positiveMeasurement(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private nonisolated static func nonnegativeMeasurement(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    // MARK: - 모니터링 시작/중지

    func startMonitoring(interval: TimeInterval = 2.0) {
        stopMonitoring()

        batteryInfo = readBatteryInfo()
        guard runsMonitoringInfrastructure else { return }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.batteryInfo = self.readBatteryInfo()
            }
        }

        registerPowerSourceNotification()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
    }

    // MARK: - IOPowerSource Notification

    private func registerPowerSourceNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.batteryInfo = monitor.readBatteryInfo()
            }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    // MARK: - Sleep 제어

    private var sleepAssertionID: IOPMAssertionID = 0

    func preventSleep(reason: String) -> Bool {
        if let preventSleepHandler {
            let didPreventSleep = preventSleepHandler(reason)
            isSleepPreventionActive = didPreventSleep
            return didPreventSleep
        }
        // 이전 assertion이 남아있으면 해제 후 재생성 — 누수 방지
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &sleepAssertionID
        )
        let didPreventSleep = result == kIOReturnSuccess
        if !didPreventSleep { sleepAssertionID = 0 }
        isSleepPreventionActive = didPreventSleep
        return didPreventSleep
    }

    func allowSleep() {
        if let allowSleepHandler {
            allowSleepHandler()
            isSleepPreventionActive = false
            return
        }
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
        isSleepPreventionActive = false
    }
}
