import Foundation

struct SafetyTemperatureCache: Equatable, Sendable {
    private(set) var value: Double?
    private(set) var recordedAt: Date?

    mutating func record(_ value: Double, at date: Date) {
        self.value = value
        recordedAt = date
    }

    mutating func clear() {
        value = nil
        recordedAt = nil
    }

    func recentValue(at date: Date, maxAge: TimeInterval) -> Double? {
        guard maxAge.isFinite,
              maxAge >= 0,
              let value,
              let recordedAt else {
            return nil
        }
        let age = date.timeIntervalSince(recordedAt)
        guard age >= 0, age <= maxAge else { return nil }
        return value
    }
}
