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

    var errorDescription: String? {
        let observations: [SleepStatusSettlementObservation]
        let reason: String
        switch self {
        case .persistentMismatch(let values):
            observations = values
            reason = "control state did not settle"
        case .unsafeWorkerState(let values):
            observations = values
            reason = "Maintain worker state was ambiguous"
        case .deadlineExceeded(let values):
            observations = values
            reason = "the end-to-end IOKit acknowledgement deadline expired"
        case .cancelled(let values):
            observations = values
            reason = "verification was cancelled"
        case .readFailed(let values, let message):
            observations = values
            reason = "status read failed: \(message)"
        }
        let last = observations.last?.status.diagnosticDescription ?? "no status was observed"
        return "Sleep charging protection verification failed: \(reason) after \(observations.count) attempt(s); last status: \(last)"
    }
}

extension SMCKit {
    // MARK: - Status

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
                maximum: statusCommandTimeout,
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

            let status: BatteryControlStatus
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
                throw SleepStatusSettlementError.readFailed(
                    observations,
                    error.localizedDescription
                )
            }
            let now = monotonicNow()
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
