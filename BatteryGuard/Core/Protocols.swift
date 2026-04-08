// Protocols.swift
// Dependency abstractions for testability

import Foundation

/// Battery CLI operations — abstracted from SMCKit for testing
protocol BatteryCLIProtocol {
    func open() throws
    func maintain(level: Int) throws -> String
    func maintainStop() throws -> String
    func chargingOff() throws -> String
    func chargingOn() throws -> String
    func discharge(to level: Int) throws -> String
    func charge(to level: Int) throws -> String
    func status() throws -> String
    func verifyMaintain(expectedLevel: Int) -> Bool
    func terminateLongProcess()
    func setMagSafeLED(_ state: MagSafeLEDState) throws
    func readBatteryTemperature() throws -> Float
}

/// Battery state monitoring — abstracted from BatteryMonitor for testing
protocol BatteryMonitorProtocol: AnyObject {
    var batteryInfo: BatteryInfo? { get }
    func startMonitoring(interval: TimeInterval)
    func stopMonitoring()
    func preventSleep(reason: String) -> Bool
    func allowSleep()
}

/// Battery history persistence — abstracted from BatteryHistory for testing
protocol BatteryHistoryProtocol {
    func record(chargePercent: Int, chargeLimit: Int)
    func fetchLast24Hours() -> [BatteryHistory.ChartRecord]
}

// MARK: - Conformances

extension SMCKit: BatteryCLIProtocol {}
extension BatteryMonitor: BatteryMonitorProtocol {}
extension BatteryHistory: BatteryHistoryProtocol {}
