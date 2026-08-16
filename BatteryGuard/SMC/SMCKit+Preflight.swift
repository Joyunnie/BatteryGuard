// SMCKit+Preflight.swift

import Foundation
import Darwin

extension SMCKit {
    func open() async throws {
        try await withGate(controlGate) {
            try await openUnlocked()
        }
    }

    private func openUnlocked() async throws {
        batteryExecutableIdentity = try validateExecutableBeforeUse(
            path: batteryPath,
            expectedProductionPath: defaultBatteryPath,
            displayName: "battery CLI"
        )
        smcExecutableIdentity = try validateExecutableBeforeUse(
            path: smcBinaryPath,
            expectedProductionPath: defaultSMCBinaryPath,
            displayName: "SMC binary"
        )
        rawSMCAvailable = true
        if let temperatureReaderPath {
            do {
                temperatureReaderExecutableIdentity = try validateTemperatureReaderBeforeUse(
                    path: temperatureReaderPath
                )
                bundledTemperatureReaderState = .untested
            } catch {
                temperatureReaderExecutableIdentity = nil
                bundledTemperatureReaderState = .incompatible(error.localizedDescription)
                await diagnostics.record(
                    DiagnosticEvent(
                        category: .sensor,
                        operation: "validate bundled SMC temperature reader",
                        outcome: .failed,
                        message: error.localizedDescription
                    )
                )
            }
        }

        try await validateBatteryCLIVersionUnlocked()
        _ = try await readControlStatusUnlocked()
        print("[SMCKit] battery CLI and SMC binary ready")
    }

    private func validateExecutableBeforeUse(
        path: String,
        expectedProductionPath: String,
        displayName: String
    ) throws -> ExecutableIdentity {
        guard path.hasPrefix("/") else {
            throw BatteryError.preflightFailed("\(displayName) path is not absolute: \(path)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BatteryError.binaryNotFound(
                "\(displayName) is not installed at \(path). Install and verify it manually before enabling charge control."
            )
        }

        switch executableTrustPolicy {
        case .production:
            guard path == expectedProductionPath else {
                throw BatteryError.preflightFailed(
                    "\(displayName) must use the pinned path \(expectedProductionPath), received \(path)"
                )
            }
            try validateRootOwnedPath(path, expectedType: S_IFREG, displayName: displayName)
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try validateRootOwnedPath(parent, expectedType: S_IFDIR, displayName: "\(displayName) directory")
        case .testFixture:
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & S_IXUSR != 0 else {
                throw BatteryError.preflightFailed("test fixture is not an executable regular file: \(path)")
            }
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw BatteryError.preflightFailed("could not capture \(displayName) identity")
        }
        return executableIdentity(from: metadata)
    }

    private func validateRootOwnedPath(
        _ path: String,
        expectedType: mode_t,
        displayName: String
    ) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw BatteryError.preflightFailed("could not inspect \(displayName) at \(path): \(String(cString: strerror(errno)))")
        }
        guard metadata.st_mode & S_IFMT == expectedType else {
            throw BatteryError.preflightFailed("\(displayName) must not be a symlink and has the wrong file type: \(path)")
        }
        guard metadata.st_uid == 0, metadata.st_gid == 0 else {
            throw BatteryError.preflightFailed("\(displayName) must be owned by root:wheel: \(path)")
        }
        guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw BatteryError.preflightFailed("\(displayName) is writable by group or others: \(path)")
        }
        if expectedType == S_IFREG, metadata.st_mode & S_IXUSR == 0 {
            throw BatteryError.preflightFailed("\(displayName) is not owner-executable: \(path)")
        }
    }

    private func validateTemperatureReaderBeforeUse(path: String) throws -> ExecutableIdentity {
        guard path.hasPrefix("/") else {
            throw BatteryError.preflightFailed(
                "SMC temperature reader path is not absolute: \(path)"
            )
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BatteryError.binaryNotFound(
                "SMC temperature reader is unavailable at \(path)"
            )
        }
        if executableTrustPolicy == .production {
            let expectedPath = bundledTemperatureReaderPath()
            guard path == expectedPath else {
                throw BatteryError.preflightFailed(
                    "SMC temperature reader must use the bundled path \(expectedPath)"
                )
            }
            let helperDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            var directoryMetadata = stat()
            guard lstat(helperDirectory, &directoryMetadata) == 0,
                  directoryMetadata.st_mode & S_IFMT == S_IFDIR,
                  directoryMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                throw BatteryError.preflightFailed(
                    "SMC temperature reader directory is not a trusted directory"
                )
            }
        }

        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & S_IXUSR != 0,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw BatteryError.preflightFailed(
                "SMC temperature reader is not a trusted executable regular file"
            )
        }
        return executableIdentity(from: metadata)
    }

    private func validateBatteryCLIVersionUnlocked() async throws {
        guard executableTrustPolicy == .production else { return }
        let result = try await runProcess(
            executable: "/bin/bash",
            arguments: [batteryPath, "version"],
            environment: batteryEnvironment,
            label: "battery version",
            timeout: statusCommandTimeout
        )
        guard let version = Self.parseSemanticVersion(result.stdout),
              version == [1, 3, 4] else {
            throw BatteryError.preflightFailed(
                "Only the verified battery CLI v1.3.4 contract is supported; received \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    private static func parseSemanticVersion(_ output: String) -> [Int]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionText = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let fields = versionText.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let components = fields.compactMap { Int($0) }
        return components.count == fields.count ? components : nil
    }

}
