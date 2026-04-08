// ChargeController.swift
// battery CLI를 통한 충전 제어 중앙 컨트롤러

import Foundation
import AppKit

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

    private let batteryQueue = DispatchQueue(label: "com.batteryguard.cli", qos: .userInitiated)
    private let smcQueue = DispatchQueue(label: "com.batteryguard.smc", qos: .utility)

    private(set) var magSafeLED: MagSafeLEDController!

    private var cachedSMCTemperature: Double = 0
    private var smcTempTimer: Timer?
    private var lastLEDState: MagSafeLEDState?
    private var isLEDBlinking = false
    private var chargeLimitDebounceWork: DispatchWorkItem?
    private var hasVerifiedMaintain = false

    // MARK: - Init

    func initialize() throws {
        print("[ChargeController] Initializing with battery CLI...")

        batteryQueue.async {
            let killTask = Process()
            killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killTask.arguments = ["-f", "battery maintain_synchronous"]
            try? killTask.run()
            killTask.waitUntilExit()
            print("[ChargeController] Stale battery processes cleaned up (pkill exit=\(killTask.terminationStatus))")
        }

        try smc.open()
        magSafeLED = MagSafeLEDController(smc: smc, settings: settings)

        monitor.startMonitoring()
        startDisplayLoop()
        startSMCTempLoop()
        setupSleepWakeObservers()

        runBattery {
            try self.applyMaintain()
            print("[ChargeController] Initialized — battery CLI managing charge control")
        }
    }

    // MARK: - Battery CLI execution

    private func runBattery(_ work: @escaping () throws -> Void) {
        #if DEBUG
        print("[ChargeController] runBattery: enqueueing task")
        #endif
        batteryQueue.async { [weak self] in
            #if DEBUG
            print("[ChargeController] runBattery: task STARTED")
            #endif
            do {
                try work()
                #if DEBUG
                print("[ChargeController] runBattery: task COMPLETED")
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

    // MARK: - Display loop (read-only)

    private func startDisplayLoop() {
        controlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateDisplayState()
        }
    }

    // MARK: - SMC temperature cache

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
                    // IOKit temperature used as fallback
                }
            }
        }
    }

    private func updateDisplayState() {
        guard let info = monitor.batteryInfo else { return }

        let pluggedIn = info.isPluggedIn || isDischarging || isTopUpActive

        guard pluggedIn else {
            currentState = .notConnected
            return
        }

        if settings.heatProtectionEnabled {
            checkHeatProtection(batteryInfo: info)
            if heatProtectionTriggered {
                currentState = .chargingPaused
                updateLED()
                return
            }
        }

        if isTopUpActive {
            if info.currentCharge >= 100 {
                completeTopUp()
            } else {
                currentState = .topUp
                updateLED()
                return
            }
        }

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
        lastTemperature = max(cachedSMCTemperature, batteryInfo.temperature)
        let threshold = settings.heatProtectionThreshold

        guard !heatProtectionPending else { return }

        if lastTemperature > threshold && !heatProtectionTriggered {
            print("[ChargeController] Heat protection triggered: \(String(format: "%.1f", lastTemperature))°C > \(threshold)°C")
            heatProtectionTriggered = true

            if isDischarging {
                print("[ChargeController] Discharge active — skipping charging off")
            } else {
                heatProtectionPending = true
                runBattery {
                    defer { DispatchQueue.main.async { self.heatProtectionPending = false } }
                    try self.smc.chargingOff()
                }
            }
        } else if lastTemperature <= (threshold - 2.0) && heatProtectionTriggered {
            print("[ChargeController] Heat protection cleared: \(String(format: "%.1f", lastTemperature))°C")
            heatProtectionTriggered = false

            if isDischarging || isTopUpActive {
                print("[ChargeController] Active action running — no restore needed")
            } else {
                heatProtectionPending = true
                runBattery {
                    defer { DispatchQueue.main.async { self.heatProtectionPending = false } }
                    try self.applyMaintain()
                }
            }
        }
    }

    // MARK: - MagSafe LED

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
            self.heatProtectionTriggered = false
            self.lastLEDState = nil
            self.runBattery { try self.applyMaintain() }
        }
    }

    // MARK: - User actions

    func setChargeLimit(_ limit: Int) {
        let clamped = max(20, min(100, limit))
        settings.chargeLimit = clamped

        guard !isDischarging && !isTopUpActive else { return }

        if let info = monitor.batteryInfo {
            if info.currentCharge >= clamped {
                currentState = .chargingPaused
            } else if info.isPluggedIn {
                currentState = .charging
            }
        }

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

        isDischarging = true
        currentState = .discharging
        _ = monitor.preventSleep(reason: "BatteryGuard: Discharge in progress")

        let target = settings.chargeLimit
        runBattery {
            print("[ChargeController] Starting discharge to \(target)%")
            do {
                try self.smc.discharge(to: target)
            } catch {
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
        isDischarging = false
        currentState = .chargingPaused
        monitor.allowSleep()
        smc.terminateLongProcess()
        runBattery {
            print("[ChargeController] Stopping discharge → resume maintain")
            try self.applyMaintain()
        }
    }

    func startTopUp() {
        if isDischarging { stopDischarge() }

        isTopUpActive = true
        currentState = .topUp

        runBattery {
            print("[ChargeController] Starting Top Up → charge to 100%")
            do {
                try self.smc.charge(to: 100)
            } catch {
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
        isTopUpActive = false
        currentState = .chargingPaused
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

    func toggleCharging() {
        guard let info = monitor.batteryInfo else { return }
        if currentState == .chargingPaused || currentState == .discharging {
            setChargeLimit(100)
        } else {
            setChargeLimit(info.currentCharge)
        }
    }

    // MARK: - Helpers

    private func applyMaintain() throws {
        let (shouldSkip, limit) = DispatchQueue.main.sync {
            (isDischarging || isTopUpActive, settings.chargeLimit)
        }
        guard !shouldSkip else {
            print("[ChargeController] applyMaintain SKIPPED — active action running")
            return
        }
        try smc.maintain(level: limit)

        // Only verify on first successful maintain — subsequent calls are trusted
        // unless they throw. Avoids spawning battery status after every slider change.
        if !hasVerifiedMaintain {
            hasVerifiedMaintain = true
            let expectedLevel = limit
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
                if !SMCKit.shared.verifyMaintain(expectedLevel: expectedLevel) {
                    print("[ChargeController] WARNING: maintain \(expectedLevel) may not have applied correctly")
                    DispatchQueue.main.async {
                        self?.lastError = "battery maintain \(expectedLevel) 적용 확인 실패"
                    }
                }
            }
        }
    }

    // MARK: - Shutdown

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

        smc.terminateLongProcess()

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? self.smc.maintainStop()
            if self.settings.controlMagSafeLED {
                try? self.smc.setMagSafeLED(.auto)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        print("[ChargeController] Shutdown complete")
    }
}
