import Foundation

enum HeatMeasurementContext: Equatable, Sendable {
    case batteryInfoAvailable
    case batteryInfoUnavailable
}

enum HeatProtectionAction: Equatable, Sendable {
    case none
    case enter(previous: RestorableChargeMode)
    case restore(previous: RestorableChargeMode)
}

struct HeatProtectionInput: Equatable {
    let temperature: Double?
    let threshold: Double
    let measurementContext: HeatMeasurementContext
    let mode: ChargeMode
    let effectiveLimit: Int
    let ownership: BatteryControlOwnership
    let retryAfter: Date?
    let now: Date
}

struct HeatProtectionEvaluation: Equatable, Sendable {
    let temperature: Double?
    let action: HeatProtectionAction
}

enum HeatProtectionPolicy {
    private static let restoreHysteresis = 2.0

    static func evaluate(_ input: HeatProtectionInput) -> HeatProtectionEvaluation {
        let temperature = input.temperature.flatMap(BatteryMonitor.validatedTemperature)
        let threshold = UserSettings.validatedHeatProtectionThreshold(input.threshold)
        guard case .batteryGuard = input.ownership else {
            return HeatProtectionEvaluation(temperature: temperature, action: .none)
        }

        let previous = input.mode.restorableMode
            ?? .maintaining(limit: UserSettings.validatedChargeLimit(input.effectiveLimit))
        let retryAllowed = input.retryAfter.map { retryAfter in
            retryAfter.timeIntervalSinceReferenceDate.isFinite && input.now >= retryAfter
        } ?? true

        guard let temperature else {
            return HeatProtectionEvaluation(
                temperature: nil,
                action: canEnter(mode: input.mode, retryAllowed: retryAllowed)
                    ? .enter(previous: previous)
                    : .none
            )
        }

        if temperature > threshold {
            if case .transitioning(.restoringHeat(let restoringPrevious)) = input.mode {
                return HeatProtectionEvaluation(
                    temperature: temperature,
                    action: .enter(previous: restoringPrevious)
                )
            }
            return HeatProtectionEvaluation(
                temperature: temperature,
                action: canEnter(mode: input.mode, retryAllowed: retryAllowed)
                    ? .enter(previous: previous)
                    : .none
            )
        }

        guard temperature <= threshold - restoreHysteresis else {
            return HeatProtectionEvaluation(temperature: temperature, action: .none)
        }
        switch input.mode {
        case .heatBlocked(let blockedPrevious):
            return HeatProtectionEvaluation(
                temperature: temperature,
                action: .restore(previous: blockedPrevious)
            )
        case .failed(let failedPrevious?, _, true)
            where input.measurementContext == .batteryInfoAvailable && retryAllowed:
            return HeatProtectionEvaluation(
                temperature: temperature,
                action: .restore(previous: failedPrevious)
            )
        default:
            return HeatProtectionEvaluation(temperature: temperature, action: .none)
        }
    }

    private static func canEnter(mode: ChargeMode, retryAllowed: Bool) -> Bool {
        guard retryAllowed else { return false }
        switch mode {
        case .heatBlocked, .controlDisabled, .transitioning(.enteringHeat):
            return false
        case .externalDrift(.controlReleasing, _), .externalDrift(.controlReleased, _):
            return false
        default:
            return true
        }
    }
}
