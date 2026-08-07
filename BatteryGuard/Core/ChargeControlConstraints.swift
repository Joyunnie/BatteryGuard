enum ChargeControlConstraints {
    nonisolated static let limitRange = 20...100

    nonisolated static func validatedLimit(_ value: Int) -> Int {
        min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }
}
