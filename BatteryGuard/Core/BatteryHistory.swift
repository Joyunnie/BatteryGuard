// BatteryHistory.swift
// Core Data-backed 24-hour battery history.

import Foundation
import CoreData

final class BatteryRecord: NSManagedObject {
    @NSManaged var timestamp: Date
    @NSManaged var chargePercent: Int16
    @NSManaged var chargeLimit: Int16
}

private enum BatteryHistoryError: LocalizedError {
    case missingEntity
    case injected(String)

    var errorDescription: String? {
        switch self {
        case .missingEntity:
            return "BatteryRecord entity is missing from the persistent store model."
        case .injected(let message):
            return message
        }
    }
}

enum BatteryHistoryOperation: Equatable, Sendable {
    case save
    case fetch
}

@MainActor
final class BatteryHistory {
    static let shared = BatteryHistory(diagnostics: .shared)

    struct ChartRecord: Equatable {
        let timestamp: Date
        let chargePercent: Int
        let chargeLimit: Int
    }

    private(set) var lastError: String?

    private let container: NSPersistentContainer
    private let inMemory: Bool
    private let diagnostics: DiagnosticLog
    private let now: @Sendable () -> Date
    private let heartbeatInterval: TimeInterval
    private let failureMessage: @Sendable (BatteryHistoryOperation) -> String?
    private var isStoreReady = false
    private var pendingRecord: (chargePercent: Int, chargeLimit: Int)?
    private var lastChargePercent: Int?
    private var lastChargeLimit: Int?
    private var lastRecordDate: Date?
    private var lastCleanupDate: Date?

    init(
        inMemory: Bool = false,
        storeURL: URL? = nil,
        heartbeatInterval: TimeInterval = 15 * 60,
        diagnostics: DiagnosticLog = .disabled,
        failureMessage: @escaping @Sendable (BatteryHistoryOperation) -> String? = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inMemory = inMemory
        self.diagnostics = diagnostics
        self.now = now
        self.heartbeatInterval = heartbeatInterval
        self.failureMessage = failureMessage

        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "BatteryRecord"
        entity.managedObjectClassName = NSStringFromClass(BatteryRecord.self)

        let timestamp = NSAttributeDescription()
        timestamp.name = "timestamp"
        timestamp.attributeType = .dateAttributeType
        timestamp.isOptional = false

        let chargePercent = NSAttributeDescription()
        chargePercent.name = "chargePercent"
        chargePercent.attributeType = .integer16AttributeType
        chargePercent.isOptional = false

        let chargeLimit = NSAttributeDescription()
        chargeLimit.name = "chargeLimit"
        chargeLimit.attributeType = .integer16AttributeType
        chargeLimit.isOptional = false

        entity.properties = [timestamp, chargePercent, chargeLimit]
        entity.indexes = [
            NSFetchIndexDescription(
                name: "idx_timestamp",
                elements: [NSFetchIndexElementDescription(property: timestamp, collationType: .binary)]
            )
        ]
        model.entities = [entity]

        container = NSPersistentContainer(name: "BatteryGuardHistory", managedObjectModel: model)
        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        } else {
            let resolvedURL = storeURL ?? Self.productionStoreURL()
            description = NSPersistentStoreDescription(url: resolvedURL)
            do {
                try FileManager.default.createDirectory(
                    at: resolvedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                lastError = "이력 저장 폴더를 만들지 못했습니다: \(error.localizedDescription)"
            }
        }
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        container.persistentStoreDescriptions = [description]
        container.viewContext.automaticallyMergesChangesFromParent = true

        container.loadPersistentStores { [weak self] _, error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let errorMessage {
                    self.reportError("Core Data store load failed: \(errorMessage)")
                    return
                }
                self.isStoreReady = true
                if let pending = self.pendingRecord {
                    self.pendingRecord = nil
                    self.record(chargePercent: pending.chargePercent, chargeLimit: pending.chargeLimit)
                }
            }
        }
    }

    func record(chargePercent: Int, chargeLimit: Int) {
        guard isStoreReady else {
            pendingRecord = (chargePercent, chargeLimit)
            return
        }

        let timestamp = now()
        let valuesChanged = chargePercent != lastChargePercent || chargeLimit != lastChargeLimit
        let heartbeatDue = lastRecordDate.map { timestamp.timeIntervalSince($0) >= heartbeatInterval } ?? true
        guard valuesChanged || heartbeatDue else { return }

        let context = container.viewContext
        let needsCleanup = lastCleanupDate.map { timestamp.timeIntervalSince($0) >= 3600 } ?? true
        do {
            if needsCleanup {
                try removeRecords(olderThan: timestamp.addingTimeInterval(-86400), from: context)
                lastCleanupDate = timestamp
            }

            guard let entity = NSEntityDescription.entity(forEntityName: "BatteryRecord", in: context) else {
                throw BatteryHistoryError.missingEntity
            }
            let record = BatteryRecord(entity: entity, insertInto: context)
            record.timestamp = timestamp
            record.chargePercent = Int16(chargePercent)
            record.chargeLimit = Int16(chargeLimit)
            if let message = failureMessage(.save) {
                throw BatteryHistoryError.injected(message)
            }
            try context.save()

            lastChargePercent = chargePercent
            lastChargeLimit = chargeLimit
            lastRecordDate = timestamp
            lastError = nil
        } catch {
            context.rollback()
            reportError("Core Data save failed: \(error.localizedDescription)")
        }
    }

    func fetchLast24Hours() -> [ChartRecord] {
        guard isStoreReady else { return [] }
        let request = NSFetchRequest<BatteryRecord>(entityName: "BatteryRecord")
        request.predicate = NSPredicate(
            format: "timestamp >= %@",
            now().addingTimeInterval(-86400) as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            if let message = failureMessage(.fetch) {
                throw BatteryHistoryError.injected(message)
            }
            let records = try container.viewContext.fetch(request)
            return records.map {
                ChartRecord(
                    timestamp: $0.timestamp,
                    chargePercent: Int($0.chargePercent),
                    chargeLimit: Int($0.chargeLimit)
                )
            }
        } catch {
            reportError("Core Data fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    static func downsample(_ records: [ChartRecord], maxPoints: Int) -> [ChartRecord] {
        guard maxPoints > 0 else { return [] }
        guard records.count > maxPoints else { return records }
        guard maxPoints > 1 else { return [records[records.count - 1]] }

        let lastIndex = records.count - 1
        return (0..<maxPoints).map { position in
            let index = position * lastIndex / (maxPoints - 1)
            return records[index]
        }
    }

    private func removeRecords(olderThan cutoff: Date, from context: NSManagedObjectContext) throws {
        if inMemory {
            let request = NSFetchRequest<BatteryRecord>(entityName: "BatteryRecord")
            request.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
            try context.fetch(request).forEach(context.delete)
            return
        }

        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "BatteryRecord")
        request.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
        let delete = NSBatchDeleteRequest(fetchRequest: request)
        delete.resultType = .resultTypeObjectIDs
        if let result = try context.execute(delete) as? NSBatchDeleteResult,
           let objectIDs = result.result as? [NSManagedObjectID],
           !objectIDs.isEmpty {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                into: [context]
            )
        }
    }

    private func reportError(_ message: String) {
        lastError = message
        print("[BatteryHistory] \(message)")
        let diagnostics = diagnostics
        Task {
            await diagnostics.record(
                DiagnosticEvent(
                    category: .history,
                    operation: "battery history",
                    termination: "failed",
                    stderrSummary: message
                )
            )
        }
    }

    private nonisolated static func productionStoreURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("BatteryGuard", isDirectory: true)
            .appendingPathComponent("BatteryHistory.sqlite")
    }
}
