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
        initialMode: ChargeMode? = nil,
        history: BatteryHistory? = nil,
        diagnostics: DiagnosticLog = .disabled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> (ChargeController, FakeChargeBackend, BatteryMonitor, UserSettings) {
        let backend = FakeChargeBackend()
        backend.temperature = temperature.map(Float.init)
        let monitor = BatteryMonitor(
            batteryInfoProvider: { nil },
            runsMonitoringInfrastructure: false,
            preventSleepHandler: { _ in true },
            allowSleepHandler: {}
        )
        monitor.batteryInfo = makeBatteryInfo(
            charge: charge,
            isCharging: isCharging,
            temperature: temperature
        )
        let settings = UserSettings(
            defaults: makeTestDefaults(),
            launchAtLoginService: FakeLaunchAtLoginService()
        )
        settings.heatProtectionEnabled = heatProtectionEnabled
        return (
            ChargeController(
                backend: backend,
                monitor: monitor,
                settings: settings,
                initialReadiness: .ready,
                initialMode: initialMode,
                history: history,
                diagnostics: diagnostics,
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
