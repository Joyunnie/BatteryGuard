// SMCKit+Temperature.swift

import Foundation

extension SMCKit {
    // MARK: - Battery temperature

    func readBatteryTemperature() async throws -> BatteryTemperatureSample {
        guard rawSMCAvailable else {
            throw BatteryError.unsupported("Raw SMC binary is unavailable; battery temperature cannot be read")
        }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let budgetNanoseconds = UInt64(smcTemperatureTotalBudget * 1_000_000_000)
        let deadlineResult = startedAt.addingReportingOverflow(budgetNanoseconds)
        guard !deadlineResult.overflow else {
            throw BatteryError.commandTimedOut("SMC temperature read")
        }
        let deadline = deadlineResult.partialValue

        if bundledTemperatureReaderState.shouldAttempt(at: startedAt),
           let temperatureReaderPath,
           temperatureReaderExecutableIdentity != nil {
            do {
                try revalidateExecutableIdentity(
                    path: temperatureReaderPath,
                    expected: temperatureReaderExecutableIdentity,
                    displayName: "SMC temperature reader"
                )
                let result = try await runProcess(
                    executable: temperatureReaderPath,
                    arguments: [],
                    label: "read battery temperatures",
                    timeout: try remainingTemperatureBudget(until: deadline)
                )
                let readings = Self.parseBatteryTemperatureReadings(result.stdout)
                if readings.hasCompleteCoverage, let maximum = readings.maximum {
                    bundledTemperatureReaderState = .available
                    return .complete(maximum)
                }
                bundledTemperatureReaderState = .incompatible(
                    "output did not contain complete TB0T/TB1T/TB2T coverage"
                )
                await diagnostics.record(
                    DiagnosticEvent(
                        category: .sensor,
                        operation: "read bundled battery temperatures",
                        outcome: .failed,
                        message: "output did not contain complete TB0T/TB1T/TB2T coverage"
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BatteryError {
                switch error {
                case .commandCancelled, .commandTimedOut:
                    throw error
                default:
                    bundledTemperatureReaderState = retryState(
                        after: temperatureReaderRetryDelay
                    )
                    await diagnostics.record(
                        DiagnosticEvent(
                            category: .sensor,
                            operation: "read bundled battery temperatures",
                            outcome: .failed,
                            message: error.localizedDescription
                        )
                    )
                }
            } catch {
                bundledTemperatureReaderState = retryState(
                    after: temperatureReaderRetryDelay
                )
                await diagnostics.record(
                    DiagnosticEvent(
                        category: .sensor,
                        operation: "read bundled battery temperatures",
                        outcome: .failed,
                        message: error.localizedDescription
                    )
                )
            }
        }

        try revalidateExecutableIdentity(
            path: smcBinaryPath,
            expected: smcExecutableIdentity,
            displayName: "SMC binary"
        )

        let batchAttemptStartedAt = DispatchTime.now().uptimeNanoseconds
        if batchedTemperatureReaderState.shouldAttempt(at: batchAttemptStartedAt) {
            do {
                let result = try await runProcess(
                    executable: smcBinaryPath,
                    arguments: ["-t"],
                    label: "smc -t",
                    timeout: min(
                        smcTemperatureReadTimeout,
                        try remainingTemperatureBudget(until: deadline)
                    )
                )
                let readings = Self.parseBatteryTemperatureReadings(result.stdout)
                if readings.hasCompleteCoverage, let maximum = readings.maximum {
                    batchedTemperatureReaderState = .available
                    return .complete(maximum)
                }
                batchedTemperatureReaderState = .incompatible(
                    "output did not contain complete TB0T/TB1T/TB2T coverage"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BatteryError {
                switch error {
                case .commandCancelled, .commandTimedOut:
                    throw error
                default:
                    batchedTemperatureReaderState = retryState(
                        after: temperatureReaderRetryDelay
                    )
                }
                // Older or variant SMC binaries do not all expose the same `-t`
                // listing. Fall through to the proven per-key read contract.
            } catch {
                batchedTemperatureReaderState = retryState(
                    after: temperatureReaderRetryDelay
                )
            }
        }

        var valuesByKey: [String: Float] = [:]
        var failures: [String] = []
        let keys = ["TB0T", "TB1T", "TB2T"]
        for (index, key) in keys.enumerated() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                failures.append(contentsOf: keys[index...].map { "\($0): total deadline expired" })
                break
            }
            let remaining = TimeInterval(deadline - now) / 1_000_000_000
            do {
                let result = try await runProcess(
                    executable: smcBinaryPath,
                    arguments: ["-k", key, "-r"],
                    label: "smc -k \(key) -r",
                    timeout: min(smcTemperatureReadTimeout, remaining)
                )
                guard let value = Self.parseBatteryTemperatureReadings(result.stdout)
                    .valuesByKey[key] else {
                    failures.append("\(key): unrecognized output")
                    continue
                }
                valuesByKey[key] = value
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BatteryError {
                if case .commandCancelled = error { throw error }
                failures.append("\(key): \(error.localizedDescription)")
            } catch {
                failures.append("\(key): \(error.localizedDescription)")
            }
        }
        guard let maximum = valuesByKey.values.max() else {
            throw BatteryError.commandFailed(
                "smc temperature read",
                -1,
                failures.joined(separator: "; ")
            )
        }
        if valuesByKey.count != keys.count {
            for key in keys where valuesByKey[key] == nil && !failures.contains(where: { $0.hasPrefix("\(key):") }) {
                failures.append("\(key): no reading")
            }
        }
        return BatteryTemperatureSample(maximum: maximum, failures: failures)
    }

    private func remainingTemperatureBudget(until deadline: UInt64) throws -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            throw BatteryError.commandTimedOut("SMC temperature read")
        }
        return min(
            smcTemperatureReadTimeout,
            TimeInterval(deadline - now) / 1_000_000_000
        )
    }

    private func retryState(after delay: TimeInterval) -> TemperatureSourceState {
        let now = DispatchTime.now().uptimeNanoseconds
        let delayNanoseconds = UInt64(delay * 1_000_000_000)
        let retryAt = now.addingReportingOverflow(delayNanoseconds)
        return .retryAfter(retryAt.overflow ? UInt64.max : retryAt.partialValue)
    }

    static func parseBatteryTemperatureList(_ output: String) -> Float? {
        parseBatteryTemperatureReadings(output).maximum
    }

    private static func parseBatteryTemperatureReadings(
        _ output: String
    ) -> BatteryTemperatureReadings {
        let supportedKeys = Set(["TB0T", "TB1T", "TB2T"])
        var valuesByKey: [String: Float] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let rawKey = fields.first else { continue }
            let key = String(rawKey)
            guard supportedKeys.contains(key),
                  let bracketEnd = line.range(of: "]"),
                  let bytesStart = line.range(of: "(bytes"),
                  bracketEnd.upperBound <= bytesStart.lowerBound else {
                continue
            }
            let text = line[bracketEnd.upperBound..<bytesStart.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard let rawValue = Float(text),
                  let value = BatteryMonitor.validatedTemperature(Double(rawValue)) else {
                continue
            }
            valuesByKey[key] = Float(value)
        }
        return BatteryTemperatureReadings(valuesByKey: valuesByKey)
    }

}
