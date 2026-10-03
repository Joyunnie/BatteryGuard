// SMCKit+Status.swift

import Foundation

struct SleepStatusSettlementObservation: Equatable, Sendable {
    let attempt: Int
    let elapsedNanoseconds: UInt64
    let status: BatteryControlStatus
}

struct SleepStatusSettlementResult: Equatable, Sendable {
    let status: BatteryControlStatus
    let observations: [SleepStatusSettlementObservation]
}

enum SleepStatusSettlementError: Error, LocalizedError, Equatable, Sendable {
    case persistentMismatch([SleepStatusSettlementObservation])
    case unsafeWorkerState([SleepStatusSettlementObservation])
    case deadlineExceeded([SleepStatusSettlementObservation])
    case cancelled([SleepStatusSettlementObservation])
    case readFailed([SleepStatusSettlementObservation], String)

    var observations: [SleepStatusSettlementObservation] {
        switch self {
        case .persistentMismatch(let values),
             .unsafeWorkerState(let values),
             .deadlineExceeded(let values),
             .cancelled(let values),
             .readFailed(let values, _):
            return values
        }
    }

    var errorDescription: String? {
        let reason: String
        switch self {
        case .persistentMismatch:
            reason = "control state did not settle"
        case .unsafeWorkerState:
            reason = "Maintain worker state was ambiguous"
        case .deadlineExceeded:
            reason = "the end-to-end IOKit acknowledgement deadline expired"
        case .cancelled:
            reason = "verification was cancelled"
        case .readFailed(_, let message):
            reason = "status read failed: \(message)"
        }
        let last = observations.last?.status.diagnosticDescription ?? "no status was observed"
        return "Sleep charging protection verification failed: \(reason) after \(observations.count) attempt(s); last status: \(last)"
    }
}

extension SMCKit {
    // MARK: - Status

    func readControlStatusUntilSettled(
        target: String,
        deadlineUptimeNanoseconds requestedDeadline: UInt64? = nil,
        matches: (BatteryControlStatus) -> Bool
    ) async throws -> BatteryControlStatus {
        let operationID = DiagnosticContext.operationID ?? UUID()
        return try await DiagnosticContext.$operationID.withValue(operationID) {
        let startedAt = monotonicNow()
        let deadline: UInt64
        if let requestedDeadline {
            deadline = requestedDeadline
        } else {
            let end = monotonicNow().addingReportingOverflow(6_000_000_000)
            deadline = end.overflow ? UInt64.max : end.partialValue
        }
        let backoffs: [UInt64] = [100_000_000, 250_000_000]
        var lastStatus: BatteryControlStatus?
        var attempts = 0
        do {
        for attempt in 0...backoffs.count {
            try Task.checkCancellation()
            guard monotonicNow() < deadline else {
                if let lastStatus {
                    await recordControlVerification(
                        target: target, attempts: attempts,
                        startedAt: startedAt, lastStatus: lastStatus,
                        outcome: .failed
                    )
                    return lastStatus
                }
                throw BatteryError.commandTimedOut("status_csv verification deadline")
            }
            attempts += 1
            do {
                let status = try await readControlStatusUnlocked(
                    deadlineUptimeNanoseconds: deadline
                )
                if matches(status) {
                    if attempts > 1 {
                        await recordControlVerification(
                            target: target, attempts: attempts,
                            startedAt: startedAt, lastStatus: status,
                            outcome: .succeeded
                        )
                    }
                    return status
                }
                lastStatus = status
                switch status.maintainWorker {
                case .stale, .duplicate, .unknown:
                    await recordControlVerification(
                        target: target, attempts: attempts,
                        startedAt: startedAt, lastStatus: status,
                        outcome: .failed
                    )
                    return status
                case .running, .stopped: break
                }
            } catch {
                guard case BatteryError.commandTimedOut = error,
                      attempt < backoffs.count else { throw error }
            }
            guard attempt < backoffs.count else { break }
            let next = monotonicNow().addingReportingOverflow(backoffs[attempt])
            guard !next.overflow, next.partialValue < deadline else {
                if let lastStatus {
                    await recordControlVerification(
                        target: target, attempts: attempts,
                        startedAt: startedAt, lastStatus: lastStatus,
                        outcome: .failed
                    )
                    return lastStatus
                }
                throw BatteryError.commandTimedOut("status_csv verification deadline")
            }
            try await monotonicSleepUntil(next.partialValue)
        }
        if let lastStatus {
            await recordControlVerification(
                target: target, attempts: attempts,
                startedAt: startedAt, lastStatus: lastStatus,
                outcome: .failed
            )
            return lastStatus
        }
        throw BatteryError.commandTimedOut("status_csv verification deadline")
        } catch {
            await recordControlVerification(
                target: target, attempts: attempts,
                startedAt: startedAt, lastStatus: lastStatus,
                outcome: error is CancellationError ? .cancelled : .failed
            )
            throw error
        }
        }
    }

    private func recordControlVerification(
        target: String,
        attempts: Int,
        startedAt: UInt64,
        lastStatus: BatteryControlStatus?,
        outcome: DiagnosticOutcome
    ) async {
        let current = monotonicNow()
        await diagnostics.record(
            DiagnosticEvent(
                category: .control,
                operation: "settle control status",
                outcome: outcome,
                controlVerification: ControlVerificationDiagnostic(
                    target: target,
                    attempts: attempts,
                    elapsedNanoseconds: current >= startedAt ? current - startedAt : 0,
                    lastStatus: lastStatus?.diagnosticDescription
                )
            )
        )
    }

    func readControlStatus() async throws -> BatteryControlStatus {
        try await withGate(controlGate) {
            try await readControlStatusUnlocked()
        }
    }

    func readControlStatusUnlocked(
        deadlineUptimeNanoseconds: UInt64? = nil
    ) async throws -> BatteryControlStatus {
        let result = try await batteryCommand(
            ["status_csv"],
            timeout: try boundedSleepPreparationTimeout(
                maximum: statusCommandTotalTimeout,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
        )
        guard let parsedStatus = Self.parseControlStatus(csv: result.stdout) else {
            throw BatteryError.unsupported("Installed battery CLI returned an unsupported status_csv format")
        }
        let workerStatus = try await readMaintainWorkerStatusUnlocked(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        return BatteryControlStatus(
            charging: parsedStatus.charging,
            isDischarging: parsedStatus.isDischarging,
            maintainLevel: parsedStatus.maintainLevel,
            maintainWorker: workerStatus
        )
    }

    func verifyChargingDisabledForSystemSleep(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> BatteryControlStatus {
        let operationID = DiagnosticContext.operationID ?? UUID()
        return try await DiagnosticContext.$operationID.withValue(operationID) {
            try await withGate(controlGate) {
                try await verifyChargingDisabledUntilSettled(
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
            }
        }
    }

    func verifyChargingDisabledUntilSettled(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> BatteryControlStatus {
        do {
            let result = try await performChargingDisabledSettlement(
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            await recordSleepStatusSettlement(
                outcome: .succeeded,
                observations: result.observations,
                error: nil
            )
            return result.status
        } catch {
            let observations: [SleepStatusSettlementObservation]
            let outcome: DiagnosticOutcome
            switch error {
            case SleepStatusSettlementError.persistentMismatch(let values),
                 SleepStatusSettlementError.unsafeWorkerState(let values):
                observations = values
                outcome = .failed
            case SleepStatusSettlementError.deadlineExceeded(let values):
                observations = values
                outcome = .timedOut
            case SleepStatusSettlementError.cancelled(let values):
                observations = values
                outcome = .cancelled
            case SleepStatusSettlementError.readFailed(let values, _):
                observations = values
                outcome = .failed
            case BatteryError.commandTimedOut:
                observations = []
                outcome = .timedOut
            default:
                observations = []
                outcome = .failed
            }
            await recordSleepStatusSettlement(
                outcome: outcome,
                observations: observations,
                error: error
            )
            throw error
        }
    }

    private func performChargingDisabledSettlement(
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> SleepStatusSettlementResult {
        let startedAt = monotonicNow()
        var observations: [SleepStatusSettlementObservation] = []

        for attempt in 1...(sleepStatusSettlementBackoffs.count + 1) {
            do {
                try Task.checkCancellation()
            } catch {
                throw SleepStatusSettlementError.cancelled(observations)
            }
            guard deadlineUptimeNanoseconds.map({ monotonicNow() < $0 }) ?? true else {
                throw SleepStatusSettlementError.deadlineExceeded(observations)
            }

            let status: BatteryControlStatus?
            do {
                status = try await readControlStatusUnlocked(
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
            } catch {
                if let deadlineUptimeNanoseconds, monotonicNow() >= deadlineUptimeNanoseconds {
                    throw SleepStatusSettlementError.deadlineExceeded(observations)
                }
                if error is CancellationError {
                    throw SleepStatusSettlementError.cancelled(observations)
                }
                if case BatteryError.commandCancelled = error {
                    throw SleepStatusSettlementError.cancelled(observations)
                }
                if case BatteryError.commandTimedOut = error,
                   attempt <= sleepStatusSettlementBackoffs.count {
                    status = nil
                } else {
                    throw SleepStatusSettlementError.readFailed(
                        observations,
                        error.localizedDescription
                    )
                }
            }
            let now = monotonicNow()
            if let status {
                observations.append(
                    SleepStatusSettlementObservation(
                        attempt: attempt,
                        elapsedNanoseconds: now >= startedAt ? now - startedAt : 0,
                        status: status
                    )
                )

                if status.isVerifiedChargingDisabled {
                    return SleepStatusSettlementResult(
                        status: status,
                        observations: observations
                    )
                }
                switch status.maintainWorker {
                case .stale, .duplicate, .unknown:
                    throw SleepStatusSettlementError.unsafeWorkerState(observations)
                case .running, .stopped:
                    break
                }
            }

            guard attempt <= sleepStatusSettlementBackoffs.count else {
                throw SleepStatusSettlementError.persistentMismatch(observations)
            }
            let delay = sleepStatusSettlementBackoffs[attempt - 1]
            let sleepDeadline = now.addingReportingOverflow(delay)
            guard !sleepDeadline.overflow,
                  deadlineUptimeNanoseconds.map({ sleepDeadline.partialValue < $0 }) ?? true else {
                throw SleepStatusSettlementError.deadlineExceeded(observations)
            }
            do {
                try await monotonicSleepUntil(sleepDeadline.partialValue)
            } catch {
                if error is CancellationError {
                    throw SleepStatusSettlementError.cancelled(observations)
                }
                throw error
            }
        }

        throw SleepStatusSettlementError.persistentMismatch(observations)
    }

    private func recordSleepStatusSettlement(
        outcome: DiagnosticOutcome,
        observations: [SleepStatusSettlementObservation],
        error: Error?
    ) async {
        let elapsed = observations.last?.elapsedNanoseconds ?? 0
        let summary = "attempts=\(observations.count),elapsedNs=\(elapsed)"
        let message = error.map { "\(summary),error=\($0.localizedDescription)" } ?? summary
        await diagnostics.record(
            DiagnosticEvent(
                category: .lifecycle,
                operation: "settle sleep charging status",
                outcome: outcome,
                message: message,
                stateBefore: observations.first?.status.diagnosticDescription,
                stateAfter: observations.last?.status.diagnosticDescription
            )
        )
    }

}
