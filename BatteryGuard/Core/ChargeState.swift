// ChargeState.swift

import Foundation

enum ChargeState: String {
    case unknown = "상태 확인 필요"
    case charging = "충전 중"
    case chargingPaused = "충전 일시정지"
    case discharging = "방전 중"
    case notConnected = "전원 미연결"
    case topUp = "Top Up 중"
}

enum ReconciliationTrigger: String, Equatable, Sendable {
    case periodic
    case appActivation
    case manual
}

enum ObservedChargeMode: Equatable, Sendable {
    case maintaining(limit: Int)
    case charging
    case discharging
    case chargingDisabled
    case unavailable(String)
    case inconsistent(String)

    var diagnosticLabel: String {
        switch self {
        case .maintaining(let limit): return "maintaining(limit:\(limit))"
        case .charging: return "charging"
        case .discharging: return "discharging"
        case .chargingDisabled: return "chargingDisabled"
        case .unavailable(let message): return "unavailable(\(message))"
        case .inconsistent(let status): return "inconsistent(\(status))"
        }
    }

    var userDescription: String {
        switch self {
        case .maintaining(let limit): return "Maintain \(limit)%"
        case .charging: return "충전 명령 활성"
        case .discharging: return "방전 명령 활성"
        case .chargingDisabled: return "충전 비활성"
        case .unavailable(let message): return "실제 충전 상태를 확인할 수 없음: \(message)"
        case .inconsistent: return "CLI가 모순된 충전 상태를 보고함"
        }
    }
}

enum ReconciledChargeExpectation: Equatable, Sendable {
    case maintaining(limit: Int)
    case toppingUp(returnLimit: Int)
    case discharging(target: Int, returnLimit: Int)
    case chargingDisabled(previous: RestorableChargeMode)

    var restorableMode: RestorableChargeMode {
        switch self {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .chargingDisabled(let previous): return previous
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .maintaining(let limit): return "maintaining(limit:\(limit))"
        case .toppingUp(let returnLimit): return "toppingUp(returnLimit:\(returnLimit))"
        case .discharging(let target, let returnLimit):
            return "discharging(target:\(target),returnLimit:\(returnLimit))"
        case .chargingDisabled(let previous):
            return "chargingDisabled(previous:\(previous.diagnosticLabel))"
        }
    }

    var userDescription: String {
        switch self {
        case .maintaining(let limit): return "Maintain \(limit)%"
        case .toppingUp: return "Top Up"
        case .discharging(let target, _): return "Discharge \(target)%"
        case .chargingDisabled: return "충전 비활성"
        }
    }
}

enum ChargeControllerReadiness: Equatable {
    case initializing
    case reconciling
    case establishingControl
    case ready
    case failed(String)
    case shuttingDown

    var diagnosticLabel: String {
        switch self {
        case .initializing: return "initializing"
        case .reconciling: return "reconciling"
        case .establishingControl: return "establishingControl"
        case .ready: return "ready"
        case .failed(let message): return "failed(\(message))"
        case .shuttingDown: return "shuttingDown"
        }
    }
}

enum RestorableChargeMode: Equatable, Sendable {
    case maintaining(limit: Int)
    case toppingUp(returnLimit: Int)
    case discharging(target: Int, returnLimit: Int)

    var maintainLimit: Int {
        switch self {
        case .maintaining(let limit): return limit
        case .toppingUp(let returnLimit): return returnLimit
        case .discharging(_, let returnLimit): return returnLimit
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .maintaining(let limit): return "maintaining(limit:\(limit))"
        case .toppingUp(let returnLimit): return "toppingUp(returnLimit:\(returnLimit))"
        case .discharging(let target, let returnLimit):
            return "discharging(target:\(target),returnLimit:\(returnLimit))"
        }
    }
}

enum ChargeTransition: Equatable {
    case applyingMaintain(target: Int, previous: RestorableChargeMode?)
    case startingTopUp(returnLimit: Int)
    case stoppingTopUp(returnLimit: Int)
    case startingDischarge(target: Int, returnLimit: Int)
    case stoppingDischarge(returnLimit: Int)
    case enteringHeat(previous: RestorableChargeMode)
    case restoringHeat(previous: RestorableChargeMode)
    case recoveringMaintain(limit: Int)

    var previousMode: RestorableChargeMode? {
        switch self {
        case .applyingMaintain(_, let previous): return previous
        case .startingTopUp(let limit), .stoppingTopUp(let limit), .recoveringMaintain(let limit):
            return .maintaining(limit: limit)
        case .startingDischarge(_, let limit):
            return .maintaining(limit: limit)
        case .stoppingDischarge(let limit):
            return .maintaining(limit: limit)
        case .enteringHeat(let previous), .restoringHeat(let previous):
            return previous
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .applyingMaintain(let target, let previous):
            return "applyingMaintain(target:\(target),previous:\(previous?.diagnosticLabel ?? "none"))"
        case .startingTopUp(let returnLimit): return "startingTopUp(returnLimit:\(returnLimit))"
        case .stoppingTopUp(let returnLimit): return "stoppingTopUp(returnLimit:\(returnLimit))"
        case .startingDischarge(let target, let returnLimit):
            return "startingDischarge(target:\(target),returnLimit:\(returnLimit))"
        case .stoppingDischarge(let returnLimit): return "stoppingDischarge(returnLimit:\(returnLimit))"
        case .enteringHeat(let previous): return "enteringHeat(previous:\(previous.diagnosticLabel))"
        case .restoringHeat(let previous): return "restoringHeat(previous:\(previous.diagnosticLabel))"
        case .recoveringMaintain(let limit): return "recoveringMaintain(limit:\(limit))"
        }
    }
}

enum ChargeMode: Equatable {
    case idle
    case maintaining(limit: Int)
    case toppingUp(returnLimit: Int)
    case discharging(target: Int, returnLimit: Int)
    case heatBlocked(previous: RestorableChargeMode)
    case transitioning(ChargeTransition)
    case externalDrift(expected: ReconciledChargeExpectation, observed: ObservedChargeMode)
    case failed(previous: RestorableChargeMode?, message: String, controlsBlocked: Bool)

    var restorableMode: RestorableChargeMode? {
        switch self {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .heatBlocked(let previous): return previous
        case .transitioning(let transition): return transition.previousMode
        case .externalDrift(let expected, _): return expected.restorableMode
        case .failed(let previous, _, _): return previous
        case .idle: return nil
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .idle: return "idle"
        case .maintaining(let limit): return "maintaining(limit:\(limit))"
        case .toppingUp(let returnLimit): return "toppingUp(returnLimit:\(returnLimit))"
        case .discharging(let target, let returnLimit):
            return "discharging(target:\(target),returnLimit:\(returnLimit))"
        case .heatBlocked(let previous): return "heatBlocked(previous:\(previous.diagnosticLabel))"
        case .transitioning(let transition): return "transitioning(\(transition.diagnosticLabel))"
        case .externalDrift(let expected, let observed):
            return "externalDrift(expected:\(expected.diagnosticLabel),observed:\(observed.diagnosticLabel))"
        case .failed(let previous, let message, let controlsBlocked):
            return "failed(previous:\(previous?.diagnosticLabel ?? "none"),blocked:\(controlsBlocked),message:\(message))"
        }
    }
}

enum BatteryDisplay {
    static func amperage(_ value: Int?) -> String {
        guard let value else { return "알 수 없음" }
        if value > 0 { return "+\(value) mA (충전)" }
        if value < 0 { return "\(value) mA (방전)" }
        return "0 mA (대기)"
    }

    static func measurement(_ value: Int?, unit: String = "") -> String {
        guard let value else { return "알 수 없음" }
        return unit.isEmpty ? "\(value)" : "\(value) \(unit)"
    }

    static func capacity(maximum: Int?, design: Int?) -> String {
        guard let maximum, let design else { return "알 수 없음" }
        return "\(maximum)/\(design) mAh"
    }
}
