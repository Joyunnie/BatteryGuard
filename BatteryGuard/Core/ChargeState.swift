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

enum BatteryDisplay {
    static func amperage(_ value: Int?) -> String {
        guard let value else { return "알 수 없음" }
        if value > 0 { return "+\(value) mA (충전)" }
        if value < 0 { return "\(value) mA (방전)" }
        return "0 mA (대기)"
    }
}
