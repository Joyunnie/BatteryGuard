// ChargeController.swift
// 모든 충전 제어 기능을 조율하는 중앙 컨트롤러
// 각 Feature 모듈의 상태를 관리하고 SMC 명령을 실행

import Foundation
import Combine
import AppKit

// MARK: - ChargeState
enum ChargeState: String {
    case charging = "충전 중"
    case chargingPaused = "충전 일시정지"
    case discharging = "방전 중"
    case notConnected = "전원 미연결"
    case topUp = "Top Up 중"
    case calibrating = "캘리브레이션"
}

// MARK: - UserSettings
/// 사용자 설정값 (UserDefaults에 저장)
class UserSettings: ObservableObject {
    static let shared = UserSettings()

    @Published var chargeLimit: Int {
        didSet { UserDefaults.standard.set(chargeLimit, forKey: "chargeLimit") }
    }
    @Published var sailingLowerBound: Int {
        didSet { UserDefaults.standard.set(sailingLowerBound, forKey: "sailingLower") }
    }
    @Published var sailingEnabled: Bool {
        didSet { UserDefaults.standard.set(sailingEnabled, forKey: "sailingEnabled") }
    }
    @Published var heatProtectionEnabled: Bool {
        didSet { UserDefaults.standard.set(heatProtectionEnabled, forKey: "heatProtection") }
    }
    @Published var heatProtectionThreshold: Double {
        didSet { UserDefaults.standard.set(heatProtectionThreshold, forKey: "heatThreshold") }
    }
    @Published var autoDischargeEnabled: Bool {
        didSet { UserDefaults.standard.set(autoDischargeEnabled, forKey: "autoDischarge") }
    }
    @Published var controlMagSafeLED: Bool {
        didSet { UserDefaults.standard.set(controlMagSafeLED, forKey: "controlMagSafe") }
    }
    @Published var stopChargingOnSleep: Bool {
        didSet { UserDefaults.standard.set(stopChargingOnSleep, forKey: "stopOnSleep") }
    }

    init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "chargeLimit") == nil {
            defaults.set(80, forKey: "chargeLimit")
        }
        if defaults.object(forKey: "sailingLower") == nil {
            defaults.set(75, forKey: "sailingLower")
        }
        if defaults.object(forKey: "heatThreshold") == nil {
            defaults.set(40.0, forKey: "heatThreshold")
        }

        self.chargeLimit = defaults.integer(forKey: "chargeLimit")
        self.sailingLowerBound = defaults.integer(forKey: "sailingLower")
        self.sailingEnabled = defaults.bool(forKey: "sailingEnabled")
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.heatProtectionThreshold = defaults.double(forKey: "heatThreshold")
        self.autoDischargeEnabled = defaults.bool(forKey: "autoDischarge")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")
        self.stopChargingOnSleep = defaults.bool(forKey: "stopOnSleep")
    }
}

// MARK: - ChargeController
/// 충전 제어 중앙 관리자
/// - 2초마다 배터리 상태를 확인하고 적절한 SMC 명령을 실행
/// - 각 기능 모듈(Discharge, HeatProtection 등)의 우선순위를 관리
/// - 상태 변경 시 MagSafe LED 업데이트
final class ChargeController: ObservableObject {
    static let shared = ChargeController()

    @Published var currentState: ChargeState = .notConnected
    @Published var isDischarging = false
    @Published var isTopUpActive = false
    @Published var isCalibrating = false
    @Published var heatProtectionTriggered = false
    @Published var lastError: String?

    private let smc = SMCKit.shared
    private let monitor = BatteryMonitor.shared
    private let settings = UserSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var controlTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Feature 모듈
    private(set) var chargeLimiter: ChargeLimiter!
    private(set) var discharger: Discharger!
    private(set) var sailingMode: SailingMode!
    private(set) var heatProtection: HeatProtection!
    private(set) var calibrationMode: CalibrationMode!
    private(set) var topUp: TopUpFeature!
    private(set) var magSafeLED: MagSafeLEDController!

    // MARK: - 초기화

    func initialize() throws {
        print("[ChargeController] Initializing SMC (subprocess mode)...")
        try smc.open()
        print("[ChargeController] SMC binary found")

        // 이전 세션 잔여 상태 초기화 — clean slate
        print("[ChargeController] Resetting SMC to clean state...")
        try? smc.disableForceDischarge()  // CHIE=00
        try? smc.allowCharging()          // CHTE=00000000
        print("[ChargeController] SMC reset complete")

        do {
            let temp = try smc.readBatteryTemperature()
            print("[ChargeController] Battery temp = \(String(format: "%.1f", temp))°C")
        } catch {
            print("[ChargeController] Temp read failed (non-critical): \(error)")
        }

        chargeLimiter = ChargeLimiter(smc: smc, settings: settings)
        discharger = Discharger(smc: smc, monitor: monitor, settings: settings)
        sailingMode = SailingMode(smc: smc, monitor: monitor, settings: settings)
        heatProtection = HeatProtection(smc: smc, monitor: monitor, settings: settings)
        calibrationMode = CalibrationMode(smc: smc, monitor: monitor, settings: settings, controller: self)
        topUp = TopUpFeature(smc: smc, monitor: monitor, settings: settings)
        magSafeLED = MagSafeLEDController(smc: smc, settings: settings)

        monitor.startMonitoring()
        startControlLoop()
        setupSleepWakeObservers()
    }

    // MARK: - 메인 제어 루프

    /// 핵심 제어 루프 (2초 간격)
    /// 우선순위: Calibration > HeatProtection > TopUp > Discharge > Sailing > ChargeLimit
    private func startControlLoop() {
        controlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.runControlCycle()
        }
    }

    private func runControlCycle() {
        guard let info = monitor.batteryInfo else { return }

        // 1. 전원 연결 판단 — force discharge 시 IOKit이 ExternalConnected=false를 반환하므로
        //    사용자가 명시적으로 시작한 모드이거나 양의 전류가 흐르면 연결된 것으로 간주
        let effectivelyPluggedIn = info.isPluggedIn
            || isDischarging
            || isTopUpActive
            || isCalibrating
            || info.amperage > 0

        guard effectivelyPluggedIn else {
            currentState = .notConnected
            return
        }

        // 2. 캘리브레이션 모드 (최우선)
        if isCalibrating {
            do { try calibrationMode.runStep(batteryInfo: info) } catch { lastError = error.localizedDescription }
            currentState = .calibrating
            updateLED()
            return
        }

        // 3. Heat Protection 체크 (실패해도 다음 단계 진행)
        if settings.heatProtectionEnabled {
            do {
                let triggered = try heatProtection.check(batteryInfo: info)
                heatProtectionTriggered = triggered
                if triggered {
                    currentState = .chargingPaused
                    updateLED()
                    return
                }
            } catch {
                // 온도 읽기 실패 — Heat Protection 건너뛰고 계속 진행
                print("[ChargeController] heatProtection.check failed: \(error)")
            }
        }

        // 4. Top Up 모드
        if isTopUpActive {
            if info.currentCharge >= 100 {
                do { try topUp.deactivate() } catch { lastError = error.localizedDescription }
                isTopUpActive = false
            } else {
                currentState = .topUp
                updateLED()
                return
            }
        }

        // 5. 방전 처리 — 방전 중에는 CHTE를 건드리지 않음
        if isDischarging {
            if info.currentCharge <= settings.chargeLimit {
                do { try discharger.stop() } catch { lastError = error.localizedDescription }
                isDischarging = false
                chargeLimiter.resetState()  // CHTE 상태 동기화
                currentState = .chargingPaused
            } else {
                currentState = .discharging
            }
            updateLED()
            return
        }

        // 6. Auto Discharge
        if settings.autoDischargeEnabled && info.currentCharge > settings.chargeLimit {
            do {
                try discharger.start()
                isDischarging = true
                currentState = .discharging
                updateLED()
                return
            } catch {
                lastError = error.localizedDescription
            }
        }

        // 7. Sailing Mode — 방전 중에는 CHTE 충돌 방지를 위해 skip
        if settings.sailingEnabled && !isDischarging {
            do { try sailingMode.apply(batteryInfo: info) } catch { lastError = error.localizedDescription }
        }

        // 8. Charge Limit 적용 — 방전 중에는 skip (CHTE 쓰면 CHIE=08이 무효화됨)
        if !isDischarging {
            do { try chargeLimiter.apply(currentCharge: info.currentCharge, limit: settings.chargeLimit) } catch { lastError = error.localizedDescription }
        }

        // 9. 상태 결정 — 항상 도달
        if info.isCharging && info.currentCharge < settings.chargeLimit {
            currentState = .charging
        } else {
            currentState = .chargingPaused
        }

        updateLED()
    }

    // MARK: - MagSafe LED 업데이트

    private func updateLED() {
        guard settings.controlMagSafeLED else { return }

        do {
            switch currentState {
            case .charging, .topUp:
                try magSafeLED.setOrange()
            case .chargingPaused:
                try magSafeLED.setGreen()
            case .discharging:
                try magSafeLED.blinkOrangeGreen()
            case .calibrating:
                try magSafeLED.setOrange()
            case .notConnected:
                break
            }
        } catch {
            // LED 제어 실패는 무시
        }
    }

    // MARK: - Sleep/Wake 처리

    private func setupSleepWakeObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWillSleep()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDidWake()
        }
    }

    private func handleWillSleep() {
        if settings.stopChargingOnSleep {
            try? smc.inhibitCharging()
        }
    }

    private func handleDidWake() {
        if !isDischarging && !heatProtectionTriggered {
            try? smc.allowCharging()
        }
    }

    // MARK: - 사용자 액션

    func setChargeLimit(_ limit: Int) {
        settings.chargeLimit = max(20, min(100, limit))
        print("[ChargeController] setChargeLimit(\(settings.chargeLimit))")
        if let info = monitor.batteryInfo {
            do {
                try chargeLimiter.apply(currentCharge: info.currentCharge, limit: settings.chargeLimit)
                // 즉시 상태 반영
                if info.currentCharge >= settings.chargeLimit {
                    currentState = .chargingPaused
                } else if info.isPluggedIn {
                    currentState = .charging
                }
            } catch {
                print("[ChargeController] chargeLimit apply FAILED: \(error)")
                lastError = error.localizedDescription
            }
        }
    }

    func startDischarge() {
        guard let info = monitor.batteryInfo,
              info.currentCharge > settings.chargeLimit else { return }
        if isTopUpActive { cancelTopUp() }
        do {
            try discharger.start()
            isDischarging = true
            currentState = .discharging
            _ = monitor.preventSleep(reason: "BatteryGuard: Discharge in progress")
            refreshMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopDischarge() {
        do {
            try discharger.stop()
            isDischarging = false
            currentState = .chargingPaused
            monitor.allowSleep()
            refreshMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startTopUp() {
        if isDischarging { stopDischarge() }
        do {
            try topUp.activate()
            isTopUpActive = true
            currentState = .topUp
            refreshMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelTopUp() {
        do {
            try topUp.deactivate()
            isTopUpActive = false
            currentState = .chargingPaused
            refreshMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startCalibration() {
        if isTopUpActive { cancelTopUp() }
        if isDischarging { stopDischarge() }
        do {
            try calibrationMode.start()
            isCalibrating = true
            currentState = .calibrating
            _ = monitor.preventSleep(reason: "BatteryGuard: Calibration in progress")
            refreshMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelCalibration() {
        do {
            try calibrationMode.cancel()
            isCalibrating = false
            currentState = .chargingPaused
            monitor.allowSleep()
            refreshMonitor()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// SMC 쓰기 후 즉시 배터리 상태 갱신
    private func refreshMonitor() {
        DispatchQueue.main.async {
            self.monitor.batteryInfo = self.monitor.readBatteryInfo()
        }
    }

    /// Right-Click 토글 (충전 일시정지 <-> 충전 재개)
    func toggleCharging() {
        guard let info = monitor.batteryInfo else { return }
        if currentState == .chargingPaused || currentState == .discharging {
            setChargeLimit(100)
        } else {
            setChargeLimit(info.currentCharge)
        }
    }

    // MARK: - 정리

    func shutdown() {
        controlTimer?.invalidate()
        monitor.stopMonitoring()
        monitor.allowSleep()

        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }

        try? smc.disableForceDischarge()
        try? smc.allowCharging()
        if settings.controlMagSafeLED {
            try? smc.setMagSafeLED(.auto)
        }
        try? smc.close()
    }
}
