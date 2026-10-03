import XCTest
import Foundation
@testable import BatteryGuard

@MainActor
final class ChargeControllerSafetyTests: XCTestCase {
    func makeSUT(
        heatProtectionEnabled: Bool = false,
        temperature: Double? = 30,
        charge: Int = 80,
        isCharging: Bool = false,
        isPluggedIn: Bool = true,
        batteryInfoOnRead: BatteryInfo? = nil,
        batteryInfoProvider: (() -> BatteryInfo?)? = nil,
        powerSourceKindProvider: @escaping () -> BatteryPowerSourceKind? = { .ac },
        initialPowerConnectionObservation: PowerConnectionObservation = .stable(.connected),
        initialReadiness: ChargeControllerReadiness = .ready,
        initialMode: ChargeMode? = nil,
        sleepChargingStrategy: SleepChargingStrategy = .pauseOnSleep,
        systemPowerObserver: SystemPowerObserving = FakeSystemPowerObserver(),
        runsSystemPowerObservation: Bool = false,
        history: BatteryHistory? = nil,
        smcTemperatureSamplingInterval: TimeInterval = ChargeController.smcTemperatureSamplingInterval,
        longRunningHeartbeatInterval: TimeInterval = 30,
        historyHeartbeatInterval: TimeInterval = 15 * 60,
        diagnostics: DiagnosticLog = .disabled,
        preventSleepHandler: @escaping (String) -> Bool = { _ in true },
        allowSleepHandler: @escaping () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> (ChargeController, FakeChargeBackend, BatteryMonitor, UserSettings) {
        let backend = FakeChargeBackend()
        backend.temperature = temperature.map(Float.init)
        let initialInfo = makeBatteryInfo(
            charge: charge,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            temperature: temperature
        )
        let monitor = BatteryMonitor(
            batteryInfoProvider: batteryInfoProvider ?? { batteryInfoOnRead ?? initialInfo },
            runsMonitoringInfrastructure: false,
            preventSleepHandler: preventSleepHandler,
            allowSleepHandler: allowSleepHandler,
            powerSourceKindProvider: powerSourceKindProvider,
            initialPowerConnectionObservation: initialPowerConnectionObservation
        )
        monitor.batteryInfo = initialInfo
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = heatProtectionEnabled
        settings.sleepChargingStrategy = sleepChargingStrategy
        return (
            ChargeController(
                backend: backend,
                monitor: monitor,
                settings: settings,
                initialReadiness: initialReadiness,
                initialMode: initialMode,
                history: history,
                smcTemperatureSamplingInterval: smcTemperatureSamplingInterval,
                longRunningHeartbeatInterval: longRunningHeartbeatInterval,
                historyHeartbeatInterval: historyHeartbeatInterval,
                diagnostics: diagnostics,
                systemPowerObserver: systemPowerObserver,
                runsSystemPowerObservation: runsSystemPowerObservation,
                now: now
            ),
            backend,
            monitor,
            settings
        )
    }

    func eventually(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

}
