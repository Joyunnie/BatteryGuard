// ChargeController.swift
// 충전 제어 중앙 컨트롤러 — battery CLI를 통한 제어
//
// 모든 SMC 제어는 battery CLI에 위임.
// 제어 루프는 IOKit에서 배터리 상태를 읽어 UI에 표시만 함.
// battery CLI 호출은 모두 백그라운드 스레드에서 실행 (메인 스레드 블로킹 방지).

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

}

// MARK: - UserSettings
class UserSettings: ObservableObject {
    static let shared = UserSettings()

    @Published var chargeLimit: Int {
        didSet { UserDefaults.standard.set(chargeLimit, forKey: "chargeLimit") }
    }
    @Published var heatProtectionEnabled: Bool {
        didSet { UserDefaults.standard.set(heatProtectionEnabled, forKey: "heatProtection") }
    }
    @Published var heatProtectionThreshold: Double {
        didSet { UserDefaults.standard.set(heatProtectionThreshold, forKey: "heatThreshold") }
    }
    @Published var controlMagSafeLED: Bool {
        didSet { UserDefaults.standard.set(controlMagSafeLED, forKey: "controlMagSafe") }
    }

    init() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "chargeLimit") == nil {
            defaults.set(80, forKey: "chargeLimit")
        }
        if defaults.object(forKey: "heatThreshold") == nil {
            defaults.set(40.0, forKey: "heatThreshold")
        }

        self.chargeLimit = defaults.integer(forKey: "chargeLimit")
        self.heatProtectionEnabled = defaults.bool(forKey: "heatProtection")
        self.heatProtectionThreshold = defaults.double(forKey: "heatThreshold")
        self.controlMagSafeLED = defaults.bool(forKey: "controlMagSafe")
    }
}

// MARK: - ChargeController
/// battery CLI를 통한 충전 제어 관리자
/// - 사용자 액션: battery CLI 명령을 백그라운드에서 실행
/// - 제어 루프: IOKit 읽기 전용 (상태 표시 + 이벤트 감지)
final class ChargeController: ObservableObject {
    static let shared = ChargeController()

    @Published var currentState: ChargeState = .notConnected
    @Published var isDischarging = false
    @Published var isTopUpActive = false

    @Published var heatProtectionTriggered = false
    @Published var lastError: String?

    private let smc = SMCKit.shared
    private let monitor = BatteryMonitor.shared
    private let settings = UserSettings.shared
    private var controlTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// battery CLI 호출 전용 직렬 큐 — 메인 스레드 블로킹 방지
    private let batteryQueue = DispatchQueue(label: "com.batteryguard.cli", qos: .userInitiated)

    /// SMC 바이너리(온도/LED) 전용 직렬 큐 — 메인 스레드에서 subprocess 실행 방지 (#2, #3)
    private let smcQueue = DispatchQueue(label: "com.batteryguard.smc", qos: .utility)

    // Feature 모듈 (UI 참조용)
    private(set) var magSafeLED: MagSafeLEDController!

    // SMC 온도 캐시 — smcQueue에서 주기적 갱신 (#2)
    private var cachedSMCTemperature: Double = 0
    private var smcTempTimer: Timer?

    // LED 상태 추적 — 변경 시에만 SMC 쓰기 (#3)
    private var lastLEDState: MagSafeLEDState?
    private var isLEDBlinking = false

    // 슬라이더 디바운스 — 드래그 중 중간값 CLI 호출 방지
    private var chargeLimitDebounceWork: DispatchWorkItem?

    // MARK: - 초기화

    func initialize() throws {
        print("[ChargeController] Initializing with battery CLI...")

        // 이전 실행에서 남은 battery 프로세스가 있으면 kill — batteryQueue 교착 방지 (백그라운드)
        batteryQueue.async {
            let killTask = Process()
            killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killTask.arguments = ["-f", "battery maintain_synchronous"]
            try? killTask.run()
            killTask.waitUntilExit()
            print("[ChargeController] Stale battery processes cleaned up (pkill exit=\(killTask.terminationStatus))")
        }

        // 파일 존재 확인만 (빠름, 메인 스레드 안전)
        try smc.open()

        magSafeLED = MagSafeLEDController(smc: smc, settings: settings)

        monitor.startMonitoring()
        startDisplayLoop()
        startSMCTempLoop()
        setupSleepWakeObservers()

        // battery CLI 호출은 백그라운드에서 실행 (applyMaintain이 active action 가드 포함)
        runBattery {
            try self.applyMaintain()
            print("[ChargeController] Initialized — battery CLI managing charge control")
        }
    }

    // MARK: - 백그라운드 battery CLI 실행

    /// battery CLI 명령을 백그라운드 큐에서 실행하고 에러를 메인 스레드에서 처리
    private func runBattery(_ work: @escaping () throws -> Void) {
        #if DEBUG
        print("[ChargeController] runBattery: enqueueing task")
        #endif
        batteryQueue.async { [weak self] in
            #if DEBUG
            print("[ChargeController] runBattery: task STARTED executing")
            #endif
            do {
                try work()
                #if DEBUG
                print("[ChargeController] runBattery: task COMPLETED successfully")
                #endif
                if self?.lastError != nil {
                    DispatchQueue.main.async { self?.lastError = nil }
                }
            } catch {
                print("[ChargeController] runBattery: task FAILED — \(error)")
                DispatchQueue.main.async {
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 디스플레이 루프 (읽기 전용)

    private func startDisplayLoop() {
        controlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateDisplayState()
        }
    }

    // MARK: - SMC 온도 캐시 루프 (#2)

    /// SMC 온도를 5초마다 백그라운드에서 읽어 캐시 — 메인 스레드에서 subprocess 호출 제거
    private func startSMCTempLoop() {
        smcTempTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, self.settings.heatProtectionEnabled else { return }
            self.smcQueue.async {
                do {
                    let temp = try self.smc.readBatteryTemperature()
                    DispatchQueue.main.async {
                        self.cachedSMCTemperature = Double(temp)
                    }
                } catch {
                    // SMC 온도 읽기 실패 — IOKit 온도로 대체 (cachedSMCTemperature = 0이면 무시됨)
                }
            }
        }
    }

    private func updateDisplayState() {
        guard let info = monitor.batteryInfo else { return }

        // 전원 연결 판단
        let pluggedIn = info.isPluggedIn || isDischarging || isTopUpActive

        guard pluggedIn else {
            currentState = .notConnected
            return
        }

        // Heat Protection 체크
        if settings.heatProtectionEnabled {
            checkHeatProtection(batteryInfo: info)
            if heatProtectionTriggered {
                currentState = .chargingPaused
                updateLED()
                return
            }
        }

        // Top Up 완료 감지
        if isTopUpActive {
            if info.currentCharge >= 100 {
                completeTopUp()
            } else {
                currentState = .topUp
                updateLED()
                return
            }
        }

        // 방전 완료 감지
        if isDischarging {
            if info.currentCharge <= settings.chargeLimit {
                print("[ChargeController] Discharge complete: \(info.currentCharge)% <= \(settings.chargeLimit)%")
                isDischarging = false
                monitor.allowSleep()
                smc.terminateLongProcess()
                runBattery { try self.applyMaintain() }
            } else {
                currentState = .discharging
                updateLED()
                return
            }
        }

        // 일반 상태 결정
        if info.isCharging && info.currentCharge < settings.chargeLimit {
            currentState = .charging
        } else {
            currentState = .chargingPaused
        }

        updateLED()
    }

    // MARK: - Heat Protection

    private var lastTemperature: Double = 0
    private var heatProtectionPending = false

    private func checkHeatProtection(batteryInfo: BatteryInfo) {
        // #2: SMC 온도는 캐시에서 읽기 — 메인 스레드에서 subprocess 실행하지 않음
        lastTemperature = max(cachedSMCTemperature, batteryInfo.temperature)

        let threshold = settings.heatProtectionThreshold

        // 이미 battery CLI 호출 중이면 중복 방지
        guard !heatProtectionPending else { return }

        if lastTemperature > threshold && !heatProtectionTriggered {
            print("[ChargeController] Heat protection triggered: \(String(format: "%.1f", lastTemperature))°C > \(threshold)°C")
            heatProtectionTriggered = true

            // 방전 중이면 충전이 이미 없으므로 CLI 호출 불필요 — 방전 계속 진행
            if isDischarging {
                print("[ChargeController] Discharge active — skipping charging off (already not charging)")
            } else {
                // maintain 중이면 charging off로 충전만 차단
                heatProtectionPending = true
                runBattery {
                    // #5: defer로 pending 해제 — 에러 시에도 반드시 실행
                    defer { DispatchQueue.main.async { self.heatProtectionPending = false } }
                    try self.smc.chargingOff()
                }
            }
        } else if lastTemperature <= (threshold - 2.0) && heatProtectionTriggered {
            print("[ChargeController] Heat protection cleared: \(String(format: "%.1f", lastTemperature))°C — restoring previous state")
            heatProtectionTriggered = false

            // 방전/TopUp/캘리브레이션 중이면 이미 해당 CLI가 제어 중 — maintain 불필요
            if isDischarging || isTopUpActive {
                print("[ChargeController] Active action running — no restore needed")
            } else {
                heatProtectionPending = true
                runBattery {
                    // #5: defer로 pending 해제 — 에러 시에도 반드시 실행
                    defer { DispatchQueue.main.async { self.heatProtectionPending = false } }
                    try self.applyMaintain()
                }
            }
        }
    }

    // MARK: - MagSafe LED (#3)

    /// LED 상태를 결정하고, 변경 시에만 SMC 쓰기 — smcQueue에서 실행
    private func updateLED() {
        guard settings.controlMagSafeLED else { return }

        switch currentState {
        case .charging, .topUp:
            setLEDIfChanged(.orange)
        case .chargingPaused:
            setLEDIfChanged(.green)
        case .discharging:
            if !isLEDBlinking {
                isLEDBlinking = true
                lastLEDState = nil
                magSafeLED.startBlink(on: smcQueue)
            }
        case .notConnected:
            break
        }
    }

    /// LED 상태가 변경된 경우에만 SMC 쓰기 — 불필요한 subprocess 호출 방지
    private func setLEDIfChanged(_ state: MagSafeLEDState) {
        if isLEDBlinking {
            isLEDBlinking = false
            magSafeLED.stopBlink()
        }
        guard state != lastLEDState else { return }
        lastLEDState = state
        smcQueue.async {
            try? self.smc.setMagSafeLED(state)
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            print("[ChargeController] System will sleep")
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            print("[ChargeController] System did wake")
            guard let self = self else { return }
            // #11: wake 시 항상 maintain 재적용 — sleep 중 battery CLI가 중단될 수 있음
            self.heatProtectionTriggered = false
            self.lastLEDState = nil
            self.runBattery { try self.applyMaintain() }
        }
    }

    // MARK: - 사용자 액션

    func setChargeLimit(_ limit: Int) {
        let clamped = max(20, min(100, limit))
        settings.chargeLimit = clamped

        guard !isDischarging && !isTopUpActive else { return }

        // 즉시 UI 상태 업데이트
        if let info = monitor.batteryInfo {
            if info.currentCharge >= clamped {
                currentState = .chargingPaused
            } else if info.isPluggedIn {
                currentState = .charging
            }
        }

        // 슬라이더 드래그 중 중간값마다 CLI 호출하지 않도록 디바운스 (0.5초)
        chargeLimitDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runBattery {
                guard let self = self else { return }
                let finalLimit = DispatchQueue.main.sync { self.settings.chargeLimit }
                print("[ChargeController] setChargeLimit(\(finalLimit))")
                try self.applyMaintain()
            }
        }
        chargeLimitDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func startDischarge() {
        guard let info = monitor.batteryInfo else { return }

        if info.currentCharge <= settings.chargeLimit {
            print("[ChargeController] charge \(info.currentCharge)% <= limit \(settings.chargeLimit)% — nothing to discharge")
            return
        }

        if isTopUpActive { cancelTopUp() }

        // 즉시 UI 상태 업데이트
        isDischarging = true
        currentState = .discharging
        _ = monitor.preventSleep(reason: "BatteryGuard: Discharge in progress")

        let target = settings.chargeLimit
        runBattery {
            print("[ChargeController] Starting discharge to \(target)%")
            do {
                try self.smc.discharge(to: target)
            } catch {
                // #4: 에러 시 상태 복원
                print("[ChargeController] Discharge failed: \(error)")
                DispatchQueue.main.async {
                    self.isDischarging = false
                    self.currentState = .chargingPaused
                    self.monitor.allowSleep()
                }
                throw error
            }
        }
    }

    func stopDischarge() {
        // 즉시 UI 상태 업데이트
        isDischarging = false
        currentState = .chargingPaused
        monitor.allowSleep()

        // 장시간 프로세스 즉시 종료 후 maintain 복원
        smc.terminateLongProcess()
        runBattery {
            print("[ChargeController] Stopping discharge → resume maintain")
            try self.applyMaintain()
        }
    }

    func startTopUp() {
        if isDischarging { stopDischarge() }

        // 즉시 UI 상태 업데이트
        isTopUpActive = true
        currentState = .topUp

        runBattery {
            print("[ChargeController] Starting Top Up → charge to 100%")
            do {
                try self.smc.charge(to: 100)
            } catch {
                // #4: 에러 시 상태 복원
                print("[ChargeController] Top Up failed: \(error)")
                DispatchQueue.main.async {
                    self.isTopUpActive = false
                    self.currentState = .chargingPaused
                }
                throw error
            }
        }
    }

    func cancelTopUp() {
        // 즉시 UI 상태 업데이트
        isTopUpActive = false
        currentState = .chargingPaused

        // 장시간 프로세스 즉시 종료 후 maintain 복원
        smc.terminateLongProcess()
        runBattery {
            print("[ChargeController] Canceling Top Up → resume maintain")
            try self.applyMaintain()
        }
    }

    private func completeTopUp() {
        print("[ChargeController] Top Up complete (100%)")
        isTopUpActive = false
        currentState = .chargingPaused
        smc.terminateLongProcess()
        runBattery { try self.applyMaintain() }
    }

    /// Right-Click 토글
    func toggleCharging() {
        guard let info = monitor.batteryInfo else { return }
        if currentState == .chargingPaused || currentState == .discharging {
            setChargeLimit(100)
        } else {
            setChargeLimit(info.currentCharge)
        }
    }

    // MARK: - Helpers

    /// 현재 설정에 맞는 battery maintain 명령 실행 (batteryQueue에서 호출)
    /// 임시 작업(discharge/topUp) 중에는 호출하지 않음 —
    /// battery maintain이 실행되면 진행 중인 discharge/charge 프로세스를 kill함
    private func applyMaintain() throws {
        // #6: 메인 스레드에서 상태 플래그를 안전하게 읽기 — @Published는 thread-safe하지 않음
        let (shouldSkip, limit) = DispatchQueue.main.sync {
            (isDischarging || isTopUpActive, settings.chargeLimit)
        }
        guard !shouldSkip else {
            print("[ChargeController] applyMaintain SKIPPED — active action running")
            return
        }
        try smc.maintain(level: limit)
    }

    // MARK: - 정리

    func shutdown() {
        controlTimer?.invalidate()
        smcTempTimer?.invalidate()
        monitor.stopMonitoring()
        monitor.allowSleep()

        if isLEDBlinking {
            magSafeLED.stopBlink()
        }

        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }

        // 장시간 프로세스 정리
        smc.terminateLongProcess()

        // #13: 백그라운드에서 정리 + 5초 타임아웃 — 앱 종료 지연 방지
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? self.smc.maintainStop()
            if self.settings.controlMagSafeLED {
                try? self.smc.setMagSafeLED(.auto)
            }
            try? self.smc.close()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        print("[ChargeController] Shutdown complete — battery maintain stopped")
    }
}
