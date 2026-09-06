// BatteryMonitor.swift
// IOKit의 IOPMPowerSource를 통한 배터리 상태 모니터링
// SMC와 별개로, macOS 전원 관리 프레임워크에서 배터리 정보를 가져옴

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Combine
import OSLog
import notify

// MARK: - BatteryInfo
/// IOPMPowerSource에서 읽어오는 배터리 상태 정보
struct BatteryInfo: Equatable, Sendable {
    let currentCharge: Int           // 현재 충전 퍼센트 (0-100)
    let isCharging: Bool             // 충전 중 여부
    let isPluggedIn: Bool            // 전원 연결 여부
    let connectionEvidence: PowerConnectionEvidence
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

enum BatteryPowerSourceKind: Equatable, Sendable {
    case ac
    case battery
    case other(String)
}

enum PowerConnectionEvidence: Equatable, Sendable {
    case connected
    case disconnected
    case uncertain
}

enum StablePowerConnection: Equatable, Sendable {
    case connected
    case disconnected
}

enum PowerConnectionObservation: Equatable, Sendable {
    case stable(StablePowerConnection)
    case transitioning(previous: StablePowerConnection?)
    case uncertain(previous: StablePowerConnection?)

    var lastConfirmed: StablePowerConnection? {
        switch self {
        case .stable(let connection): return connection
        case .transitioning(let previous), .uncertain(let previous): return previous
        }
    }
}

// MARK: - BatteryMonitor
/// 배터리 상태를 주기적으로 모니터링하는 클래스
/// - IOPMPowerSource: macOS 전원 관리 프레임워크. 배터리 상태를 userspace에 노출
/// - IOServiceGetMatchingService: IOKit 레지스트리에서 AppleSmartBattery 서비스 검색
/// - IOPowerSource notification을 주 경로로 사용하고 저빈도 watchdog으로 누락을 보완
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor(runsMonitoringInfrastructure: !AppRuntime.isRunningTests)

    private struct FreshPowerSnapshot {
        let sourceKind: BatteryPowerSourceKind?
        let batteryInfo: BatteryInfo?
    }

    private static let defaultTransitionOffsetsNanoseconds: [UInt64] = [
        100_000_000,
        500_000_000,
        1_000_000_000,
        2_000_000_000
    ]

    @Published var batteryInfo: BatteryInfo?
    @Published private(set) var powerConnectionObservation: PowerConnectionObservation

    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "BatteryMonitor")
    private let batteryInfoProvider: (() -> BatteryInfo?)?
    private let runsMonitoringInfrastructure: Bool
    private let preventSleepHandler: ((String) -> Bool)?
    private let allowSleepHandler: (() -> Void)?
    private let powerSourceKindProvider: (() -> BatteryPowerSourceKind?)?
    private let transitionOffsetsNanoseconds: [UInt64]
    private let monotonicNow: @MainActor () -> UInt64
    private let transitionSleepUntil: @MainActor (UInt64) async -> Void
    private let notificationRefreshScheduler: @MainActor (DispatchWorkItem) -> Void
    private let registersBroadPowerSourceNotifications: Bool
    private let transitionNotificationRegistrar: ((@escaping @Sendable () -> Void) -> Int32?)?
    private let transitionNotificationCanceller: (Int32) -> Void
    var usesMonitoringInfrastructure: Bool { runsMonitoringInfrastructure }
    var hasActivePowerSourceSettlement: Bool { powerSourceSettlementTask != nil }
    var isWatchdogScheduled: Bool { timer != nil }
    private(set) var isSleepPreventionActive = false
    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private var notificationRefreshWork: DispatchWorkItem?
    private var presentationRefreshResetWork: DispatchWorkItem?
    private var powerSourceNotificationToken: Int32?
    private var powerSourceSettlementTask: Task<Void, Never>?
    private var pendingSettlementRefreshGeneration: UInt64?
    private var powerSourceSettlementDirectionIsConfirmed = false
    private var lastPowerSourceKind: BatteryPowerSourceKind?
    private var monitoringGeneration: UInt64 = 0
    private var powerSourceTransitionGeneration: UInt64 = 0
    private var isMonitoring = false

    init(
        batteryInfoProvider: (() -> BatteryInfo?)? = nil,
        runsMonitoringInfrastructure: Bool = true,
        preventSleepHandler: ((String) -> Bool)? = nil,
        allowSleepHandler: (() -> Void)? = nil,
        powerSourceKindProvider: (() -> BatteryPowerSourceKind?)? = nil,
        transitionOffsetsNanoseconds: [UInt64] = BatteryMonitor.defaultTransitionOffsetsNanoseconds,
        monotonicNow: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        transitionSleepUntil: @escaping @MainActor (UInt64) async -> Void = { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return }
            try? await Task.sleep(nanoseconds: deadline - now)
        },
        notificationRefreshScheduler: @escaping @MainActor (DispatchWorkItem) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        },
        registersBroadPowerSourceNotifications: Bool = true,
        transitionNotificationRegistrar: ((@escaping @Sendable () -> Void) -> Int32?)? = nil,
        transitionNotificationCanceller: @escaping (Int32) -> Void = { token in
            notify_cancel(token)
        },
        initialPowerConnectionObservation: PowerConnectionObservation = .uncertain(previous: nil)
    ) {
        self.batteryInfoProvider = batteryInfoProvider
        self.runsMonitoringInfrastructure = runsMonitoringInfrastructure
        self.preventSleepHandler = preventSleepHandler
        self.allowSleepHandler = allowSleepHandler
        self.powerSourceKindProvider = powerSourceKindProvider
        self.transitionOffsetsNanoseconds = transitionOffsetsNanoseconds.sorted()
        self.monotonicNow = monotonicNow
        self.transitionSleepUntil = transitionSleepUntil
        self.notificationRefreshScheduler = notificationRefreshScheduler
        self.registersBroadPowerSourceNotifications = registersBroadPowerSourceNotifications
        self.transitionNotificationRegistrar = transitionNotificationRegistrar
        self.transitionNotificationCanceller = transitionNotificationCanceller
        self.powerConnectionObservation = initialPowerConnectionObservation
    }

    // MARK: - Helper

    /// IOKit 딕셔너리에서 Bool 읽기. CFBoolean / NSNumber 모두 처리.
    private nonisolated static func readBool(_ dict: [String: Any], key: String, default defaultVal: Bool = false) -> Bool {
        if let b = dict[key] as? Bool { return b }
        if let n = dict[key] as? NSNumber { return n.boolValue }
        if let n = dict[key] as? Int { return n != 0 }
        return defaultVal
    }

    private nonisolated static func readOptionalBool(_ dict: [String: Any], key: String) -> Bool? {
        guard dict[key] != nil else { return nil }
        if let b = dict[key] as? Bool { return b }
        if let n = dict[key] as? NSNumber { return n.boolValue }
        if let n = dict[key] as? Int { return n != 0 }
        return nil
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

    func readPowerSourceKind() -> BatteryPowerSourceKind? {
        if let powerSourceKindProvider { return powerSourceKindProvider() }
        guard !AppRuntime.isRunningTests else { return nil }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let unmanagedType = IOPSGetProvidingPowerSourceType(snapshot) else {
            return nil
        }
        let sourceType = unmanagedType.takeUnretainedValue() as String
        switch sourceType {
        case kIOPSACPowerValue:
            return .ac
        case kIOPSBatteryPowerValue:
            return .battery
        default:
            return .other(sourceType)
        }
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
        let externalConnected = readOptionalBool(dict, key: "ExternalConnected")
        // ExternalConnected는 force discharge 시 CHIE에 의해 false로 보고됨.
        // ExternalChargeCapable / AppleRawExternalConnected는 물리적 연결 상태를 반영.
        let externalChargeCapable = readOptionalBool(dict, key: "ExternalChargeCapable")
        let rawExternalConnected = readOptionalBool(dict, key: "AppleRawExternalConnected")
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

        let connectionEvidence = Self.connectionEvidence(
            externalConnected: externalConnected,
            externalChargeCapable: externalChargeCapable,
            rawExternalConnected: rawExternalConnected,
            isCharging: isCharging
        )
        let pluggedIn = connectionEvidence == .connected

        return BatteryInfo(
            currentCharge: currentCharge,
            isCharging: isCharging,
            isPluggedIn: pluggedIn,
            connectionEvidence: connectionEvidence,
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

    nonisolated static func connectionEvidence(
        externalConnected: Bool?,
        externalChargeCapable: Bool?,
        rawExternalConnected: Bool?,
        isCharging: Bool
    ) -> PowerConnectionEvidence {
        let externalSignals = [externalConnected, externalChargeCapable, rawExternalConnected]
        if isCharging || externalSignals.contains(where: { $0 == true }) {
            return .connected
        }
        if externalSignals.allSatisfy({ $0 == false }) {
            return .disconnected
        }
        return .uncertain
    }

    nonisolated static func resolvedPowerConnection(
        info: BatteryInfo,
        sourceKind: BatteryPowerSourceKind?
    ) -> StablePowerConnection? {
        if info.connectionEvidence == .connected || sourceKind == .ac {
            return .connected
        }
        if info.connectionEvidence == .disconnected, sourceKind == .battery {
            return .disconnected
        }
        return nil
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

    func startMonitoring(interval: TimeInterval = 30.0) {
        stopMonitoring()

        monitoringGeneration &+= 1
        isMonitoring = true
        lastPowerSourceKind = nil
        refreshPowerConnectionPresentation()
        guard runsMonitoringInfrastructure else { return }

        let watchdog = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isMonitoring else { return }
                self.performWatchdogRefresh()
            }
        }
        watchdog.tolerance = min(5, max(0, interval * 0.2))
        RunLoop.main.add(watchdog, forMode: .common)
        timer = watchdog

        if registersBroadPowerSourceNotifications {
            registerPowerSourceNotification()
        }
        registerPowerSourceTransitionNotification()
        reconcilePowerSourceAfterRegistration()
    }

    /// Refreshes the controller-facing measurement only. Connection presentation
    /// deliberately uses a paired BatteryInfo/IOPS snapshot through
    /// `refreshPowerConnectionPresentation()`.
    @discardableResult
    func refreshBatteryInfo() -> Bool {
        publishBatteryInfo(readBatteryInfo())
    }

    @discardableResult
    private func publishBatteryInfo(_ freshInfo: BatteryInfo?) -> Bool {
        guard freshInfo != batteryInfo else { return false }
        batteryInfo = freshInfo
        return true
    }

    private func readFreshPowerSnapshot() -> FreshPowerSnapshot {
        let sourceKind = readPowerSourceKind()
        let batteryInfo = readBatteryInfo()
        return FreshPowerSnapshot(sourceKind: sourceKind, batteryInfo: batteryInfo)
    }

    /// Performs one paired presentation read. Before monitoring starts this is a
    /// one-shot observation and cannot create settlement or monitoring work.
    @discardableResult
    func refreshPowerConnectionPresentation() -> Bool {
        if powerSourceSettlementTask != nil {
            markSettlementRefreshPending()
            return false
        }

        let snapshot = readFreshPowerSnapshot()
        return applyFreshPowerSnapshot(snapshot)
    }

    @discardableResult
    private func applyFreshPowerSnapshot(_ snapshot: FreshPowerSnapshot) -> Bool {
        let didPublish = publishBatteryInfo(snapshot.batteryInfo)

        if let observedKind = snapshot.sourceKind {
            if isMonitoring,
               let previousKind = lastPowerSourceKind,
               previousKind != observedKind {
                lastPowerSourceKind = observedKind
                logger.notice(
                    "Presentation refresh detected transition: \(String(describing: previousKind), privacy: .public) -> \(String(describing: observedKind), privacy: .public)"
                )
                startPowerSourceSettlement(for: observedKind, directionIsConfirmed: true)
                return didPublish
            }
            lastPowerSourceKind = observedKind
        }

        updatePowerConnectionObservationIfSettled(
            using: snapshot.batteryInfo,
            sourceKind: snapshot.sourceKind
        )
        return didPublish
    }

    /// Narrow testable entry used by the real watchdog timer.
    func performWatchdogRefresh() {
        guard isMonitoring else { return }
        if powerSourceSettlementTask != nil {
            markSettlementRefreshPending()
            return
        }
        refreshPowerConnectionPresentation()
    }

    private func updatePowerConnectionObservationIfSettled(
        using info: BatteryInfo?,
        sourceKind: BatteryPowerSourceKind?
    ) {
        guard powerSourceSettlementTask == nil else { return }
        let previousConnection = powerConnectionObservation.lastConfirmed
        guard let info,
              let connection = Self.resolvedPowerConnection(
                info: info,
                sourceKind: sourceKind
              ) else {
            publishPowerConnectionObservation(.uncertain(previous: previousConnection))
            return
        }
        publishPowerConnectionObservation(.stable(connection))
    }

    private func publishPowerConnectionObservation(_ observation: PowerConnectionObservation) {
        guard observation != powerConnectionObservation else { return }
        powerConnectionObservation = observation
    }

    func stopMonitoring() {
        isMonitoring = false
        monitoringGeneration &+= 1
        powerSourceTransitionGeneration &+= 1
        powerSourceSettlementTask?.cancel()
        powerSourceSettlementTask = nil
        pendingSettlementRefreshGeneration = nil
        powerSourceSettlementDirectionIsConfirmed = false
        timer?.invalidate()
        timer = nil
        notificationRefreshWork?.cancel()
        notificationRefreshWork = nil
        presentationRefreshResetWork?.cancel()
        presentationRefreshResetWork = nil
        if let token = powerSourceNotificationToken {
            transitionNotificationCanceller(token)
            powerSourceNotificationToken = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        lastPowerSourceKind = nil
    }

    // MARK: - IOPowerSource Notification

    private func registerPowerSourceNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.handleBroadPowerSourceNotification()
            }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        } else {
            logger.warning("IOPowerSource notification registration failed; watchdog remains active")
        }
    }

    func scheduleNotificationRefresh() {
        guard isMonitoring else { return }
        if powerSourceSettlementTask != nil {
            markSettlementRefreshPending()
            return
        }
        guard notificationRefreshWork == nil,
              presentationRefreshResetWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.notificationRefreshWork = nil
            guard self.isMonitoring else { return }
            self.refreshPowerConnectionPresentation()
        }
        notificationRefreshWork = work
        notificationRefreshScheduler(work)
    }

    func handleBroadPowerSourceNotification() {
        scheduleNotificationRefresh()
    }

    /// Refreshes synchronously on the first visibility request and coalesces
    /// other requests made during the same main-run-loop turn.
    func requestPresentationRefresh() {
        if powerSourceSettlementTask != nil {
            markSettlementRefreshPending()
            return
        }
        guard presentationRefreshResetWork == nil else { return }
        notificationRefreshWork?.cancel()
        notificationRefreshWork = nil
        refreshPowerConnectionPresentation()

        let work = DispatchWorkItem { [weak self] in
            self?.presentationRefreshResetWork = nil
        }
        presentationRefreshResetWork = work
        DispatchQueue.main.async(execute: work)
    }

    func handlePowerSourceTransitionNotification() {
        guard isMonitoring else { return }
        guard let observedKind = readPowerSourceKind() else {
            if let lastPowerSourceKind, powerSourceSettlementTask == nil {
                startPowerSourceSettlement(for: lastPowerSourceKind, directionIsConfirmed: false)
            } else {
                requestPresentationRefresh()
            }
            return
        }
        guard let previousKind = lastPowerSourceKind else {
            applyFreshPowerSnapshot(
                FreshPowerSnapshot(
                    sourceKind: observedKind,
                    batteryInfo: readBatteryInfo()
                )
            )
            return
        }
        guard previousKind != observedKind else {
            // The dedicated Darwin notification is the edge signal. Its
            // payload-less callback can beat the IOPS snapshot update, so keep
            // one anchored settlement alive even when the first source read is
            // still the cached direction. Bursts cannot restart an active run.
            if powerSourceSettlementTask == nil {
                startPowerSourceSettlement(for: observedKind, directionIsConfirmed: false)
            } else {
                markSettlementRefreshPending()
            }
            return
        }

        lastPowerSourceKind = observedKind
        logger.notice(
            "Power-source transition observed: \(String(describing: previousKind), privacy: .public) -> \(String(describing: observedKind), privacy: .public)"
        )
        startPowerSourceSettlement(for: observedKind, directionIsConfirmed: true)
    }

    private func registerPowerSourceTransitionNotification() {
        let callback: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePowerSourceTransitionNotification()
            }
        }

        if let transitionNotificationRegistrar {
            guard let token = transitionNotificationRegistrar(callback) else {
                logger.warning("Power-source transition registration failed; watchdog remains active")
                return
            }
            powerSourceNotificationToken = token
            return
        }

        var token: Int32 = 0
        let status = notify_register_dispatch(
            kIOPSNotifyPowerSource,
            &token,
            DispatchQueue.main
        ) { _ in
            callback()
        }
        guard status == NOTIFY_STATUS_OK else {
            logger.warning(
                "Power-source transition registration failed with status \(status, privacy: .public); watchdog remains active"
            )
            return
        }
        powerSourceNotificationToken = token
    }

    private func reconcilePowerSourceAfterRegistration() {
        guard isMonitoring else { return }
        refreshPowerConnectionPresentation()
    }

    private func startPowerSourceSettlement(
        for initialExpectedKind: BatteryPowerSourceKind,
        directionIsConfirmed: Bool
    ) {
        powerSourceTransitionGeneration &+= 1
        let transitionGeneration = powerSourceTransitionGeneration
        let currentMonitoringGeneration = monitoringGeneration
        let anchor = monotonicNow()

        notificationRefreshWork?.cancel()
        notificationRefreshWork = nil
        presentationRefreshResetWork?.cancel()
        presentationRefreshResetWork = nil
        powerSourceSettlementTask?.cancel()
        pendingSettlementRefreshGeneration = nil
        powerSourceSettlementDirectionIsConfirmed = directionIsConfirmed
        let previousConnection = powerConnectionObservation.lastConfirmed
        publishPowerConnectionObservation(.transitioning(previous: previousConnection))

        powerSourceSettlementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastConnectionCandidate: StablePowerConnection?
            defer {
                self.finishPowerSourceSettlement(
                    generation: transitionGeneration,
                    previousConnection: previousConnection,
                    lastConnectionCandidate: lastConnectionCandidate
                )
            }

            for offset in self.transitionOffsetsNanoseconds {
                let deadline = anchor.addingReportingOverflow(offset)
                guard !deadline.overflow else { return }
                await self.transitionSleepUntil(deadline.partialValue)
                guard !Task.isCancelled,
                      self.isMonitoring,
                      self.monitoringGeneration == currentMonitoringGeneration,
                      self.powerSourceTransitionGeneration == transitionGeneration else { return }

                let observedKind = self.readPowerSourceKind()
                if let observedKind,
                   observedKind != self.lastPowerSourceKind {
                    let priorKind = self.lastPowerSourceKind ?? initialExpectedKind
                    if self.powerSourceSettlementDirectionIsConfirmed {
                        self.logger.notice(
                            "Power-source snapshot reversed during settlement: \(String(describing: priorKind), privacy: .public) -> \(String(describing: observedKind), privacy: .public)"
                        )
                        self.lastPowerSourceKind = observedKind
                        self.startPowerSourceSettlement(
                            for: observedKind,
                            directionIsConfirmed: true
                        )
                        return
                    } else {
                        self.logger.notice(
                            "Power-source snapshot converged during settlement: \(String(describing: priorKind), privacy: .public) -> \(String(describing: observedKind), privacy: .public)"
                        )
                        self.powerSourceSettlementDirectionIsConfirmed = true
                        self.lastPowerSourceKind = observedKind
                    }
                }
                let freshInfo = self.readBatteryInfo()
                guard !Task.isCancelled,
                      self.isMonitoring,
                      self.monitoringGeneration == currentMonitoringGeneration,
                      self.powerSourceTransitionGeneration == transitionGeneration else { return }

                let didPublish = self.publishBatteryInfo(freshInfo)
                let candidate = freshInfo.flatMap {
                    Self.resolvedPowerConnection(info: $0, sourceKind: observedKind)
                }
                lastConnectionCandidate = candidate
                if let candidate {
                    switch self.powerConnectionObservation {
                    case .transitioning where candidate == previousConnection:
                        break
                    default:
                        self.publishPowerConnectionObservation(.stable(candidate))
                    }
                }
                if didPublish, let freshInfo {
                    self.logger.notice(
                        "Power-transition measurement published at offset_ms=\(offset / 1_000_000, privacy: .public), plugged=\(freshInfo.isPluggedIn, privacy: .public), charging=\(freshInfo.isCharging, privacy: .public)"
                    )
                }
            }
        }
    }

    private func markSettlementRefreshPending() {
        guard powerSourceSettlementTask != nil else { return }
        pendingSettlementRefreshGeneration = powerSourceTransitionGeneration
    }

    private func finishPowerSourceSettlement(
        generation: UInt64,
        previousConnection: StablePowerConnection?,
        lastConnectionCandidate: StablePowerConnection?
    ) {
        guard powerSourceTransitionGeneration == generation else { return }
        powerSourceSettlementTask = nil
        powerSourceSettlementDirectionIsConfirmed = false

        if let lastConnectionCandidate {
            publishPowerConnectionObservation(.stable(lastConnectionCandidate))
        } else {
            publishPowerConnectionObservation(.uncertain(previous: previousConnection))
        }

        guard pendingSettlementRefreshGeneration == generation else { return }
        pendingSettlementRefreshGeneration = nil
        scheduleTrailingRefresh(
            monitoringGeneration: monitoringGeneration,
            transitionGeneration: generation
        )
    }

    private func scheduleTrailingRefresh(
        monitoringGeneration: UInt64,
        transitionGeneration: UInt64
    ) {
        guard isMonitoring, notificationRefreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.notificationRefreshWork = nil
            guard self.isMonitoring,
                  self.monitoringGeneration == monitoringGeneration,
                  self.powerSourceTransitionGeneration == transitionGeneration,
                  self.powerSourceSettlementTask == nil else { return }
            self.refreshPowerConnectionPresentation()
        }
        notificationRefreshWork = work
        notificationRefreshScheduler(work)
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
