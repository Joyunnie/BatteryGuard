// ChargeLimiter.swift
// 충전 상한 설정 기능
//
// SMC의 BCLM(Battery Charge Level Max) 키에 원하는 퍼센트 값을 기록.
// SMC 펌웨어가 이 값을 읽고 배터리 충전 IC에 최대 충전 전압을 조절하도록 명령.
// 충전 IC는 셀 전압이 해당 SoC에 도달하면 충전 FET를 차단.
// BCLM 값은 SMC NVRAM에 저장되어 재부팅 후에도 유지됨.

import Foundation

final class ChargeLimiter {
    private let smc: SMCKit
    private let settings: UserSettings

    private(set) var currentSMCLimit: UInt8 = 100

    init(smc: SMCKit, settings: UserSettings) {
        self.smc = smc
        self.settings = settings
    }

    func apply(limit: Int) throws {
        let value = UInt8(max(20, min(100, limit)))
        guard value != currentSMCLimit else { return }
        try smc.writeChargeLimit(value)
        currentSMCLimit = value
    }

    func readCurrentLimit() throws -> UInt8 {
        let value = try smc.readChargeLimit()
        currentSMCLimit = value
        return value
    }

    func release() throws {
        try apply(limit: 100)
    }
}
