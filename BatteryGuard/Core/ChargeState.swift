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

enum BatteryPresentationTone: Equatable, Sendable {
    case success
    case warning
    case info
    case neutral
    case danger
}

struct BatteryPresentation: Equatable, Sendable {
    let statusTitle: String
    let statusIcon: String
    let menuBarIcon: String
    let tone: BatteryPresentationTone
    let showsChargingBolt: Bool
    let powerIcon: String
    let powerLabel: String
    let eyebrow: String
    let headline: String

    nonisolated static func make(
        info: BatteryInfo?,
        connection: PowerConnectionObservation,
        mode: ChargeMode,
        chargeState: ChargeState,
        requiresManualRecovery: Bool
    ) -> BatteryPresentation {
        let power = PowerDescription(connection)

        if requiresManualRecovery {
            let connectedPrefix = connection == .stable(.connected) ? "전원 연결됨 · " : ""
            return BatteryPresentation(
                statusTitle: "\(connectedPrefix)충전 제어 복구 필요",
                statusIcon: "exclamationmark.triangle.fill",
                menuBarIcon: "exclamationmark.triangle.fill",
                tone: .danger,
                showsChargingBolt: false,
                powerIcon: power.icon,
                powerLabel: power.label,
                eyebrow: power.eyebrow,
                headline: "실제 충전 제어 상태를 확인해 주세요"
            )
        }

        switch mode {
        case .failed:
            return makeSafetyPresentation(
                title: "충전 제어 확인 필요",
                icon: "exclamationmark.triangle.fill",
                tone: .danger,
                headline: "충전 제어 오류를 확인해 주세요",
                power: power
            )
        case .externalDrift:
            return makeSafetyPresentation(
                title: "외부 충전 상태 확인 필요",
                icon: "arrow.triangle.2.circlepath.circle.fill",
                tone: .warning,
                headline: "외부에서 바뀐 충전 상태를 확인해 주세요",
                power: power
            )
        case .heatBlocked:
            return makeSafetyPresentation(
                title: "고온 보호 중",
                icon: "thermometer.sun.fill",
                tone: .warning,
                headline: "고온으로 충전을 잠시 멈췄어요",
                power: power
            )
        case .sleepProtected:
            return makeSafetyPresentation(
                title: "잠자기 충전 보호 중",
                icon: "moon.fill",
                tone: .info,
                headline: "잠자기 동안 충전을 멈췄어요",
                power: power
            )
        default:
            break
        }

        switch connection {
        case .transitioning:
            return BatteryPresentation(
                statusTitle: "전원 연결 상태 확인 중",
                statusIcon: "arrow.triangle.2.circlepath",
                menuBarIcon: "arrow.triangle.2.circlepath",
                tone: .info,
                showsChargingBolt: false,
                powerIcon: power.icon,
                powerLabel: power.label,
                eyebrow: power.eyebrow,
                headline: "전원 연결 변화를 확인하고 있어요"
            )
        case .uncertain:
            return BatteryPresentation(
                statusTitle: "전원 연결 상태 확인 필요",
                statusIcon: "questionmark",
                menuBarIcon: "questionmark.circle",
                tone: .warning,
                showsChargingBolt: false,
                powerIcon: power.icon,
                powerLabel: power.label,
                eyebrow: power.eyebrow,
                headline: "전원 연결 여부를 확인할 수 없어요"
            )
        case .stable:
            break
        }

        guard let info else {
            return BatteryPresentation(
                statusTitle: "상태 확인 필요",
                statusIcon: "questionmark",
                menuBarIcon: "questionmark.circle",
                tone: .danger,
                showsChargingBolt: false,
                powerIcon: power.icon,
                powerLabel: power.label,
                eyebrow: power.eyebrow,
                headline: "배터리 정보를 읽을 수 없어요"
            )
        }

        if case .toppingUp = mode {
            return makeActivityPresentation(
                title: "Top Up 중",
                icon: "arrow.up.to.line.compact",
                menuBarIcon: "bolt.fill",
                tone: .success,
                showsChargingBolt: true,
                headline: "추가 충전을 진행하고 있어요",
                power: power
            )
        }
        if case .discharging = mode {
            return makeActivityPresentation(
                title: "방전 중",
                icon: "arrow.down.to.line.compact",
                menuBarIcon: "arrow.down.circle.fill",
                tone: .info,
                showsChargingBolt: false,
                headline: "목표까지 안전하게 방전 중이에요",
                power: power
            )
        }
        if info.isCharging {
            return makeActivityPresentation(
                title: "충전 중",
                icon: "bolt.fill",
                menuBarIcon: "bolt.fill",
                tone: .success,
                showsChargingBolt: true,
                headline: "한도까지 충전하고 있어요",
                power: power
            )
        }
        if connection == .stable(.disconnected) {
            return makeActivityPresentation(
                title: ChargeState.notConnected.rawValue,
                icon: "powerplug",
                menuBarIcon: "battery.25percent",
                tone: .neutral,
                showsChargingBolt: false,
                headline: "배터리 전원으로 사용 중이에요",
                power: power
            )
        }

        if case .maintaining(let limit) = mode {
            let isHoldingAtLimit = info.currentCharge >= limit
            return makeActivityPresentation(
                title: isHoldingAtLimit ? "충전 한도 유지 중" : "전원 연결됨 · 충전 대기 중",
                icon: isHoldingAtLimit ? "pause.fill" : "powerplug.fill",
                menuBarIcon: "battery.75percent",
                tone: isHoldingAtLimit ? .success : .warning,
                showsChargingBolt: false,
                headline: isHoldingAtLimit
                    ? "설정한 충전 한도를 지키고 있어요"
                    : "macOS의 충전 시작을 기다리고 있어요",
                power: power
            )
        }

        let headline: String
        switch mode {
        case .controlDisabled:
            headline = "macOS가 충전 상태를 관리하고 있어요"
        case .transitioning:
            headline = "안전한 충전 상태로 전환 중이에요"
        default:
            headline = chargeState == .unknown
                ? "충전 상태를 확인해 주세요"
                : "설정한 범위를 지키고 있어요"
        }
        return makeActivityPresentation(
            title: chargeState.rawValue,
            icon: chargeState == .unknown ? "questionmark" : "pause.fill",
            menuBarIcon: chargeState == .unknown ? "questionmark.circle" : "battery.75percent",
            tone: chargeState == .unknown ? .warning : .info,
            showsChargingBolt: false,
            headline: headline,
            power: power
        )
    }

    private nonisolated static func makeSafetyPresentation(
        title: String,
        icon: String,
        tone: BatteryPresentationTone,
        headline: String,
        power: PowerDescription
    ) -> BatteryPresentation {
        BatteryPresentation(
            statusTitle: title,
            statusIcon: icon,
            menuBarIcon: icon,
            tone: tone,
            showsChargingBolt: false,
            powerIcon: power.icon,
            powerLabel: power.label,
            eyebrow: power.eyebrow,
            headline: headline
        )
    }

    private nonisolated static func makeActivityPresentation(
        title: String,
        icon: String,
        menuBarIcon: String,
        tone: BatteryPresentationTone,
        showsChargingBolt: Bool,
        headline: String,
        power: PowerDescription
    ) -> BatteryPresentation {
        BatteryPresentation(
            statusTitle: title,
            statusIcon: icon,
            menuBarIcon: menuBarIcon,
            tone: tone,
            showsChargingBolt: showsChargingBolt,
            powerIcon: power.icon,
            powerLabel: power.label,
            eyebrow: power.eyebrow,
            headline: headline
        )
    }

    private struct PowerDescription {
        let icon: String
        let label: String
        let eyebrow: String

        nonisolated init(_ observation: PowerConnectionObservation) {
            switch observation {
            case .stable(.connected):
                icon = "powerplug.fill"
                label = "연결됨"
                eyebrow = "전원 연결됨"
            case .stable(.disconnected):
                icon = "powerplug"
                label = "연결 안 됨"
                eyebrow = "배터리 사용 중"
            case .transitioning:
                icon = "arrow.triangle.2.circlepath"
                label = "확인 중"
                eyebrow = "전원 연결 확인 중"
            case .uncertain:
                icon = "questionmark.circle"
                label = "알 수 없음"
                eyebrow = "전원 연결 불명"
            }
        }
    }
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
    case sleepProtected(previous: RestorableChargeMode)
    case controlReleasing(lastLimit: Int)
    case controlReleased(lastLimit: Int)

    var restorableMode: RestorableChargeMode {
        switch self {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .chargingDisabled(let previous), .sleepProtected(let previous): return previous
        case .controlReleasing(let lastLimit), .controlReleased(let lastLimit):
            return .maintaining(limit: lastLimit)
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
        case .sleepProtected(let previous):
            return "sleepProtected(previous:\(previous.diagnosticLabel))"
        case .controlReleasing(let lastLimit):
            return "controlReleasing(lastLimit:\(lastLimit))"
        case .controlReleased(let lastLimit):
            return "controlReleased(lastLimit:\(lastLimit))"
        }
    }

    var userDescription: String {
        switch self {
        case .maintaining(let limit): return "Maintain \(limit)%"
        case .toppingUp: return "Top Up"
        case .discharging(let target, _): return "Discharge \(target)%"
        case .chargingDisabled: return "열 보호로 충전 비활성"
        case .sleepProtected: return "잠자기 보호로 충전 비활성"
        case .controlReleasing: return "BatteryGuard 제어 해제 미완료"
        case .controlReleased: return "BatteryGuard 제어 끔"
        }
    }

    var reconciledMode: ChargeMode {
        switch self {
        case .controlReleasing:
            return .externalDrift(
                expected: self,
                observed: .unavailable("BatteryGuard control release is still pending")
            )
        case .controlReleased(let lastLimit): return .controlDisabled(lastLimit: lastLimit)
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .chargingDisabled(let previous): return .heatBlocked(previous: previous)
        case .sleepProtected(let previous): return .sleepProtected(previous: previous, charge: nil)
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
    case preparingForSleep(previous: RestorableChargeMode)
    case recoveringMaintain(limit: Int)
    case releasingControl(previous: RestorableChargeMode?)

    var previousMode: RestorableChargeMode? {
        switch self {
        case .applyingMaintain(_, let previous): return previous
        case .startingTopUp(let limit), .stoppingTopUp(let limit), .recoveringMaintain(let limit):
            return .maintaining(limit: limit)
        case .startingDischarge(_, let limit):
            return .maintaining(limit: limit)
        case .stoppingDischarge(let limit):
            return .maintaining(limit: limit)
        case .enteringHeat(let previous), .restoringHeat(let previous), .preparingForSleep(let previous):
            return previous
        case .releasingControl(let previous): return previous
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
        case .preparingForSleep(let previous): return "preparingForSleep(previous:\(previous.diagnosticLabel))"
        case .recoveringMaintain(let limit): return "recoveringMaintain(limit:\(limit))"
        case .releasingControl(let previous):
            return "releasingControl(previous:\(previous?.diagnosticLabel ?? "none"))"
        }
    }
}

enum ChargeMode: Equatable {
    case idle
    case maintaining(limit: Int)
    case toppingUp(returnLimit: Int)
    case discharging(target: Int, returnLimit: Int)
    case heatBlocked(previous: RestorableChargeMode)
    case sleepProtected(previous: RestorableChargeMode, charge: Int?)
    case controlDisabled(lastLimit: Int)
    case transitioning(ChargeTransition)
    case externalDrift(expected: ReconciledChargeExpectation, observed: ObservedChargeMode)
    case failed(
        previous: RestorableChargeMode?,
        message: String,
        disposition: ChargeFailureDisposition
    )

    var restorableMode: RestorableChargeMode? {
        switch self {
        case .maintaining(let limit): return .maintaining(limit: limit)
        case .toppingUp(let returnLimit): return .toppingUp(returnLimit: returnLimit)
        case .discharging(let target, let returnLimit):
            return .discharging(target: target, returnLimit: returnLimit)
        case .heatBlocked(let previous): return previous
        case .sleepProtected(let previous, _): return previous
        case .transitioning(let transition): return transition.previousMode
        case .externalDrift(let expected, _): return expected.restorableMode
        case .failed(let previous, _, _): return previous
        case .controlDisabled, .idle: return nil
        }
    }

    var requiresChargingDisabledForActiveSleepTransition: Bool {
        switch self {
        case .sleepProtected, .transitioning(.preparingForSleep):
            return true
        case .failed(_, _, .manualRecovery(let context)):
            if case .systemSleep(.forcedSystemSleep) = context.origin { return true }
            return false
        default:
            return false
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
        case .sleepProtected(let previous, let charge):
            return "sleepProtected(previous:\(previous.diagnosticLabel),charge:\(charge.map(String.init) ?? "unknown"))"
        case .controlDisabled(let lastLimit): return "controlDisabled(lastLimit:\(lastLimit))"
        case .transitioning(let transition): return "transitioning(\(transition.diagnosticLabel))"
        case .externalDrift(let expected, let observed):
            return "externalDrift(expected:\(expected.diagnosticLabel),observed:\(observed.diagnosticLabel))"
        case .failed(let previous, let message, let disposition):
            return "failed(previous:\(previous?.diagnosticLabel ?? "none"),disposition:\(disposition.diagnosticLabel),message:\(message))"
        }
    }
}

enum ManualRecoveryOrigin: Equatable, Sendable {
    case systemSleep(SystemSleepRequestKind)
    case wakeRestore
    case chargeControl

    var diagnosticLabel: String {
        switch self {
        case .systemSleep(let kind): return "systemSleep(\(kind.rawValue))"
        case .wakeRestore: return "wakeRestore"
        case .chargeControl: return "chargeControl"
        }
    }
}

enum ManualRecoveryTarget: Equatable, Sendable {
    case none
    case restoreMaintain(limit: Int)

    var diagnosticLabel: String {
        switch self {
        case .none: return "none"
        case .restoreMaintain(let limit): return "restoreMaintain(limit:\(limit))"
        }
    }
}

struct ManualRecoveryContext: Equatable, Sendable {
    let origin: ManualRecoveryOrigin
    let target: ManualRecoveryTarget
    let latestObservedState: ObservedChargeMode?

    func updating(observedState: ObservedChargeMode) -> Self {
        Self(origin: origin, target: target, latestObservedState: observedState)
    }
}

enum ChargeFailureDisposition: Equatable, Sendable {
    /// The previous verified tuple may recover through read-only reconciliation.
    case recoverPrevious
    /// Heat Protection owns this failure and may retry its fail-closed transition.
    case heatProtection
    /// Hardware state is uncertain; no automatic recovery policy may reinterpret it.
    case manualIntervention
    /// Hardware state is uncertain and carries a typed, user-authorized recovery target.
    case manualRecovery(ManualRecoveryContext)

    var diagnosticLabel: String {
        switch self {
        case .recoverPrevious: return "recoverPrevious"
        case .heatProtection: return "heatProtection"
        case .manualIntervention: return "manualIntervention"
        case .manualRecovery(let context):
            return "manualRecovery(origin:\(context.origin.diagnosticLabel),target:\(context.target.diagnosticLabel),observed:\(context.latestObservedState?.diagnosticLabel ?? "none"))"
        }
    }
}

enum BatteryIssueSource: String, Hashable, Sendable {
    case command
    case externalDrift
    case sensor
    case led
}

enum BatteryIssueSeverity: Int, Equatable, Comparable, Sendable {
    case warning = 1
    case blocking = 2
    case critical = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct BatteryIssue: Identifiable, Equatable, Sendable {
    let source: BatteryIssueSource
    let severity: BatteryIssueSeverity
    let message: String
    let occurredAt: Date
    var id: String { "\(source.rawValue):\(message)" }
}

struct BatteryIssueRegistry: Sendable {
    private var entries: [BatteryIssueSource: BatteryIssue] = [:]

    mutating func set(
        _ source: BatteryIssueSource,
        severity: BatteryIssueSeverity,
        message: String?,
        at date: Date
    ) {
        guard let message else {
            entries[source] = nil
            return
        }
        if entries[source]?.message == message { return }
        entries[source] = BatteryIssue(
            source: source,
            severity: severity,
            message: message,
            occurredAt: date
        )
    }

    func message(for source: BatteryIssueSource) -> String? {
        entries[source]?.message
    }

    var orderedIssues: [BatteryIssue] {
        entries.values.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.source.rawValue < $1.source.rawValue
        }
    }
}

enum SafetyTemperatureSource: String, Equatable, Sendable {
    case smc = "SMC"
    case ioKit = "IOKit"
}

enum SafetyTemperatureFreshness: Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

struct SafetyTemperatureSnapshot: Equatable, Sendable {
    let value: Double?
    let sources: [SafetyTemperatureSource]
    let freshness: SafetyTemperatureFreshness
    let failures: [String]

    static let unavailable = SafetyTemperatureSnapshot(
        value: nil,
        sources: [],
        freshness: .unavailable,
        failures: []
    )

    var displayValue: String {
        guard let value else { return "알 수 없음" }
        let provenance = sources.map(\.rawValue).joined(separator: "+")
        let measurement = String(format: "%.1f°C (%@)", value, provenance)
        return freshness == .stale ? "\(measurement) · 오래됨" : measurement
    }
}

enum HeatProtectionPhase: Equatable, Sendable {
    case disabled
    case monitoring
    case degraded
    case entering
    case blocked
    case restoring
    case failed

    var userDescription: String {
        switch self {
        case .disabled: return "열 보호 꺼짐"
        case .monitoring: return "열 보호 모니터링"
        case .degraded: return "열 보호 센서 degraded"
        case .entering: return "열 보호 적용 중"
        case .blocked: return "열 보호 작동 중"
        case .restoring: return "열 보호 복원 중"
        case .failed: return "열 보호 실패"
        }
    }
}

enum ChargeActionAvailability: Equatable, Sendable {
    case allowed
    case denied(String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var denialReason: String? {
        guard case .denied(let reason) = self else { return nil }
        return reason
    }

    func helpText(fallback: String) -> String {
        denialReason ?? fallback
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
