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
    let maxCapacity: Int             // 최대 용량 (mAh)
    let designCapacity: Int          // 설계 용량 (mAh)
    let cycleCount: Int              // 충방전 사이클 수
    let temperature: Double          // 온도 (°C)
    let amperage: Int                // 전류 (mA, 양수=충전, 음수=방전)
    let voltage: Int                 // 전압 (mV)
    let timeToFull: Int              // 완충까지 남은 시간 (분), -1이면 N/A
    let timeToEmpty: Int             // 방전까지 남은 시간 (분), -1이면 N/A
    let healthPercent: Double        // 배터리 건강도 (%)
    let isPresent: Bool              // 배터리 존재 여부
    let serialNumber: String         // 배터리 시리얼 번호
}

// MARK: - BatteryMonitor
/// 배터리 상태를 주기적으로 모니터링하는 클래스
/// - IOPMPowerSource: macOS 전원 관리 프레임워크. 배터리 상태를 userspace에 노출
/// - IOServiceGetMatchingService: IOKit 레지스트리에서 AppleSmartBattery 서비스 검색
/// - 2초 간격 폴링 + IOPowerSource notification 조합
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published var batteryInfo: BatteryInfo?

    private var timer: Timer?
    private var historyTimer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private var hasLoggedDictOnce = false

    // MARK: - Helper

    /// IOKit 딕셔너리에서 Bool 읽기. CFBoolean / NSNumber 모두 처리.
    private func readBool(_ dict: [String: Any], key: String, default defaultVal: Bool = false) -> Bool {
        if let b = dict[key] as? Bool { return b }
        if let n = dict[key] as? NSNumber { return n.boolValue }
        if let n = dict[key] as? Int { return n != 0 }
        return defaultVal
    }

    // MARK: - IOKit을 통한 배터리 정보 읽기

    /// AppleSmartBattery 서비스에서 배터리 딕셔너리 읽기
    func readBatteryInfo() -> BatteryInfo? {
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

        // 초회 기동 시 전체 딕셔너리 덤프 (Debug 전용)
        #if DEBUG
        if !hasLoggedDictOnce {
            hasLoggedDictOnce = true
            print("[BatteryMonitor] ── AppleSmartBattery dictionary dump ──")
            let interestingKeys = [
                "CurrentCapacity", "MaxCapacity", "AppleRawMaxCapacity",
                "DesignCapacity", "IsCharging", "ExternalConnected",
                "ExternalChargeCapable", "AppleRawExternalConnected",
                "Temperature", "Amperage", "InstantAmperage", "Voltage",
                "CycleCount", "BatteryInstalled", "Serial",
                "AvgTimeToFull", "AvgTimeToEmpty", "NominalChargeCapacity",
                "AppleRawCurrentCapacity", "FullyCharged", "AtCriticalLevel"
            ]
            for key in interestingKeys {
                if let val = dict[key] {
                    print("  \(key) = \(val)  (type: \(type(of: val)))")
                } else {
                    print("  \(key) = <missing>")
                }
            }
            print("[BatteryMonitor] ── end dump ──")
        }
        #endif

        // CurrentCapacity: macOS 표시 % (0-100)
        let currentCharge = dict["CurrentCapacity"] as? Int ?? 0

        // AppleRawMaxCapacity: 실제 최대 용량 (mAh). MaxCapacity는 %라서 사용 불가.
        let rawMaxCapacity = dict["AppleRawMaxCapacity"] as? Int ?? 0
        let designCapacity = dict["DesignCapacity"] as? Int ?? 0

        let isCharging = readBool(dict, key: "IsCharging")
        let externalConnected = readBool(dict, key: "ExternalConnected")
        // #8: ExternalConnected는 force discharge 시 CHIE에 의해 false로 보고됨.
        // ExternalChargeCapable / AppleRawExternalConnected는 물리적 연결 상태를 반영.
        let externalChargeCapable = readBool(dict, key: "ExternalChargeCapable")
        let rawExternalConnected = readBool(dict, key: "AppleRawExternalConnected")
        let cycleCount = dict["CycleCount"] as? Int ?? 0

        // Temperature: 데시켈빈 (K × 10). 예: 2969 → 296.9K → 23.75°C
        let rawTemp = dict["Temperature"] as? Int ?? 0
        let tempCelsius: Double
        if rawTemp > 0 {
            tempCelsius = Double(rawTemp) / 10.0 - 273.15
        } else {
            tempCelsius = 0
        }

        // Amperage: IOKit이 signed/unsigned 혼용으로 반환할 수 있음.
        // NSNumber.intValue가 부호 변환을 올바르게 처리.
        let amperage: Int
        if let number = dict["Amperage"] as? NSNumber {
            amperage = number.intValue
        } else {
            amperage = 0
        }

        let voltage = dict["Voltage"] as? Int ?? 0
        let timeToFull = dict["AvgTimeToFull"] as? Int ?? -1
        let timeToEmpty = dict["AvgTimeToEmpty"] as? Int ?? -1
        let batteryPresent = readBool(dict, key: "BatteryInstalled", default: true)
        let serialNumber = dict["Serial"] as? String ?? "N/A"

        // 건강도: AppleRawMaxCapacity / DesignCapacity (둘 다 mAh)
        let health: Double
        if designCapacity > 0 && rawMaxCapacity > 0 {
            health = (Double(rawMaxCapacity) / Double(designCapacity)) * 100.0
        } else {
            health = 100.0
        }

        // #8: ExternalConnected 외에 ExternalChargeCapable / AppleRawExternalConnected로 보완
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

    // MARK: - 모니터링 시작/중지

    func startMonitoring(interval: TimeInterval = 2.0) {
        stopMonitoring()

        batteryInfo = readBatteryInfo()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.batteryInfo = self.readBatteryInfo()
        }

        // 60초마다 배터리 이력 기록 (Core Data)
        recordHistory()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.recordHistory()
        }

        registerPowerSourceNotification()
    }

    private func recordHistory() {
        guard let info = batteryInfo else { return }
        BatteryHistory.shared.record(chargePercent: info.currentCharge, chargeLimit: UserSettings.shared.chargeLimit)
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        historyTimer?.invalidate()
        historyTimer = nil
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
        return result == kIOReturnSuccess
    }

    func allowSleep() {
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }
}
