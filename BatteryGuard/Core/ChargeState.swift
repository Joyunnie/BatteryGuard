// ChargeState.swift

import Foundation

enum ChargeState: String {
    case charging = "충전 중"
    case chargingPaused = "충전 일시정지"
    case discharging = "방전 중"
    case notConnected = "전원 미연결"
    case topUp = "Top Up 중"
}
