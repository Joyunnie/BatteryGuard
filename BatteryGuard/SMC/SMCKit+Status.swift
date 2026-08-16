// SMCKit+Status.swift

import Foundation

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

}
