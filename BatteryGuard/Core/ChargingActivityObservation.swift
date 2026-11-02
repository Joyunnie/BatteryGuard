import Foundation
import IOKit.ps

/// Presentation evidence, never a charge-control instruction or sensor replacement.
struct PowerSourceSnapshot: Equatable, Sendable {
    let kind: BatteryPowerSourceKind?
    let isCharging: Bool?

    static let unavailable = PowerSourceSnapshot(kind: nil, isCharging: nil)

    nonisolated static func internalBatteryCharging(in descriptions: [[String: Any]]) -> Bool? {
        let batteries = descriptions.filter {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
        guard batteries.count == 1,
              let value = batteries[0][kIOPSIsChargingKey] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}

struct ChargingActivityObservation: Equatable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case charging, notCharging, conflicting, unavailable
    }

    let systemIsCharging: Bool?
    let batteryIsCharging: Bool?

    static let unavailable = ChargingActivityObservation(systemIsCharging: nil, batteryIsCharging: nil)

    var state: State {
        guard let systemIsCharging, let batteryIsCharging else { return .unavailable }
        guard systemIsCharging == batteryIsCharging else { return .conflicting }
        return batteryIsCharging ? .charging : .notCharging
    }
}

/// Read times are observation times, NOT hardware sample timestamps. Re-reading
/// an unchanged dictionary cannot establish when the sensor last sampled it.
struct PowerObservationDiagnostic: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case began, changed, connectionSettled, ended }
    enum Connection: String, Codable, Sendable {
        case connected, disconnected, transitioning, uncertain

        init(_ observation: PowerConnectionObservation) {
            switch observation {
            case .stable(.connected): self = .connected
            case .stable(.disconnected): self = .disconnected
            case .transitioning: self = .transitioning
            case .uncertain: self = .uncertain
            }
        }
    }
    let sessionID: UUID
    let generation: UInt64
    let phase: Phase
    let eventUptimeNanoseconds: UInt64
    let sampleReadUptimeNanoseconds: UInt64?
    let elapsedNanoseconds: UInt64
    let source: String?
    let activity: ChargingActivityObservation
    let amperage: Int?
    let chargePercent: Int?
    let connection: Connection
}
