// ChargeLimiter.swift
// 충전 상한 설정 기능 (Apple Silicon)
//
// Apple Silicon에는 BCLM 키가 없음. 대신 배터리 잔량을 폴링하면서
// CH0B/CH0C/CHTE 키로 충전 회로를 직접 ON/OFF하여 제한.
//   charge >= limit → inhibitCharging()
//   charge < limit  → allowCharging()
// ChargeController의 2초 제어 루프에서 매 틱마다 호출.

import Foundation

final class ChargeLimiter {
    private let smc: SMCKit
    private let settings: UserSettings

    /// 현재 충전 억제 상태
    private(set) var isInhibiting = false

    init(smc: SMCKit, settings: UserSettings) {
        self.smc = smc
        self.settings = settings
    }

    /// 현재 배터리 잔량에 따라 충전 허용/차단 결정
    func apply(currentCharge: Int, limit: Int) throws {
        if currentCharge >= limit {
            if !isInhibiting {
                try smc.inhibitCharging()
                isInhibiting = true
                print("[ChargeLimiter] charge \(currentCharge)% >= limit \(limit)% → inhibit")
            }
        } else {
            if isInhibiting {
                try smc.allowCharging()
                isInhibiting = false
                print("[ChargeLimiter] charge \(currentCharge)% < limit \(limit)% → allow")
            }
        }
    }

    /// 충전 허용 (제한 해제)
    func release() throws {
        try smc.allowCharging()
        isInhibiting = false
    }
}
