// BatteryHistory.swift
// Core Data-backed seven-day battery history.

import Foundation
import CoreData
import OSLog

final class BatteryRecord: NSManagedObject {
    @NSManaged var timestamp: Date
    @NSManaged var chargePercent: Int16
    @NSManaged var chargeLimit: Int16
}

private enum BatteryHistoryError: LocalizedError {
    case missingEntity

    var errorDescription: String? {
        switch self {
        case .missingEntity:
            return "BatteryRecord entity is missing from the persistent store model."
        }
    }
}

enum BatteryHistoryReadiness: Equatable {
    case loading
    case ready
    case failed(String)
}

struct BatteryHistoryViewport: Equatable {
    let visibleInterval: TimeInterval
    let liveEdgeTolerance: TimeInterval
    private(set) var domainEnd: Date
    var scrollPosition: Date
    private(set) var isInitialized = false

    init(
        now: Date,
        visibleInterval: TimeInterval = 24 * 60 * 60,
        liveEdgeTolerance: TimeInterval = 2 * 60
    ) {
        self.visibleInterval = visibleInterval
        self.liveEdgeTolerance = liveEdgeTolerance
        domainEnd = now
        scrollPosition = now.addingTimeInterval(-visibleInterval)
    }

    mutating func refresh(now: Date) {
        let previousLivePosition = domainEnd.addingTimeInterval(-visibleInterval)
        let followsLiveEdge = !isInitialized
            || abs(scrollPosition.timeIntervalSince(previousLivePosition)) <= liveEdgeTolerance
        domainEnd = now
        if followsLiveEdge {
            scrollPosition = now.addingTimeInterval(-visibleInterval)
        }
        isInitialized = true
    }
}

@MainActor
struct BatteryHistoryStoreOperations {
    let save: (NSManagedObjectContext) throws -> Void
    let fetch: (NSManagedObjectContext, NSFetchRequest<BatteryRecord>) throws -> [BatteryRecord]

    init(
        save: @escaping (NSManagedObjectContext) throws -> Void = { try $0.save() },
        fetch: @escaping (NSManagedObjectContext, NSFetchRequest<BatteryRecord>) throws -> [BatteryRecord] = {
            try $0.fetch($1)
        }
    ) {
        self.save = save
        self.fetch = fetch
    }
}

@MainActor
final class BatteryHistory {
    static let shared = BatteryHistory(
        inMemory: AppRuntime.isRunningTests,
        diagnostics: AppRuntime.isRunningTests ? .disabled : .shared
    )

    struct ChartRecord: Equatable {
        let timestamp: Date
        let chargePercent: Int
        let chargeLimit: Int
    }

    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private(set) var readiness: BatteryHistoryReadiness = .loading
    private(set) var saveError: String?
    private(set) var fetchError: String?
    var visibleError: String? {
        if case .failed(let message) = readiness { return message }
        return fetchError ?? saveError
    }

    private let container: NSPersistentContainer
    private let inMemory: Bool
    var usesInMemoryStore: Bool { inMemory }
    private let diagnostics: DiagnosticLog
    private let storeOperations: BatteryHistoryStoreOperations
    private let now: @Sendable () -> Date
    private let heartbeatInterval: TimeInterval
    private let logger = Logger(subsystem: "com.jiwon.batteryguard", category: "History")
    private var readinessWaiters: [CheckedContinuation<BatteryHistoryReadiness, Never>] = []
    private var pendingRecords: [(chargePercent: Int, chargeLimit: Int)] = []
    private var lastChargePercent: Int?
    private var lastChargeLimit: Int?
    private var lastRecordDate: Date?
    private var lastCleanupDate: Date?

    init(
        inMemory: Bool = false,
        storeURL: URL? = nil,
        heartbeatInterval: TimeInterval = 15 * 60,
        diagnostics: DiagnosticLog = .disabled,
        storeOperations: BatteryHistoryStoreOperations = BatteryHistoryStoreOperations(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inMemory = inMemory
        self.diagnostics = diagnostics
        self.now = now
        self.heartbeatInterval = heartbeatInterval
        self.storeOperations = storeOperations

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
                readiness = .failed("이력 저장 폴더를 만들지 못했습니다: \(error.localizedDescription)")
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
                    self.setReadinessFailure("Core Data store load failed: \(errorMessage)")
                    return
                }
                if case .failed(let message) = self.readiness {
                    self.resolveReadinessWaiters()
                    self.reportDiagnostic(message, operation: "load history store")
                    return
                }
                self.readiness = .ready
                self.resolveReadinessWaiters()
                let pendingRecords = self.pendingRecords
                self.pendingRecords.removeAll()
                for pending in pendingRecords {
                    self.record(chargePercent: pending.chargePercent, chargeLimit: pending.chargeLimit)
                }
            }
        }
    }

    func waitUntilReady() async -> BatteryHistoryReadiness {
        guard readiness == .loading else { return readiness }
        return await withCheckedContinuation { readinessWaiters.append($0) }
    }

    func loadRecentHistory() async -> [ChartRecord] {
        guard await waitUntilReady() == .ready else { return [] }
        return fetchRecentHistory()
    }

    @discardableResult
    func record(chargePercent: Int, chargeLimit: Int) -> Bool {
        guard (0...100).contains(chargePercent),
              UserSettings.chargeLimitRange.contains(chargeLimit) else {
            reportError(
                "History rejected invalid values: charge=\(chargePercent), limit=\(chargeLimit)",
                operation: "validate history sample"
            )
            return false
        }
        guard readiness == .ready else {
            if readiness == .loading {
                pendingRecords.append((chargePercent, chargeLimit))
                if pendingRecords.count > 256 {
                    pendingRecords.removeFirst(pendingRecords.count - 256)
                }
                return true
            }
            return false
        }

        let timestamp = now()
        let valuesChanged = chargePercent != lastChargePercent || chargeLimit != lastChargeLimit
        let heartbeatDue = lastRecordDate.map { timestamp.timeIntervalSince($0) >= heartbeatInterval } ?? true
        guard valuesChanged || heartbeatDue else { return false }

        let context = container.viewContext
        let needsCleanup = lastCleanupDate.map { timestamp.timeIntervalSince($0) >= 3600 } ?? true
        do {
            if needsCleanup {
                try removeRecords(
                    olderThan: timestamp.addingTimeInterval(-Self.retentionInterval),
                    from: context
                )
                lastCleanupDate = timestamp
            }

            guard let entity = NSEntityDescription.entity(forEntityName: "BatteryRecord", in: context) else {
                throw BatteryHistoryError.missingEntity
            }
            let record = BatteryRecord(entity: entity, insertInto: context)
            record.timestamp = timestamp
            record.chargePercent = Int16(chargePercent)
            record.chargeLimit = Int16(chargeLimit)
            try storeOperations.save(context)

            lastChargePercent = chargePercent
            lastChargeLimit = chargeLimit
            lastRecordDate = timestamp
            saveError = nil
            return true
        } catch {
            context.rollback()
            reportError("Core Data save failed: \(error.localizedDescription)", operation: "save history")
            return false
        }
    }

    func fetchRecentHistory() -> [ChartRecord] {
        guard readiness == .ready else { return [] }
        let request = NSFetchRequest<BatteryRecord>(entityName: "BatteryRecord")
        request.predicate = NSPredicate(
            format: "timestamp >= %@",
            now().addingTimeInterval(-Self.retentionInterval) as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let records = try storeOperations.fetch(container.viewContext, request)
            fetchError = nil
            return records.map {
                ChartRecord(
                    timestamp: $0.timestamp,
                    chargePercent: Int($0.chargePercent),
                    chargeLimit: Int($0.chargeLimit)
                )
            }
        } catch {
            reportError("Core Data fetch failed: \(error.localizedDescription)", operation: "fetch history")
            return []
        }
    }

    static func downsample(_ records: [ChartRecord], maxPoints: Int) -> [ChartRecord] {
        guard maxPoints > 0 else { return [] }
        guard records.count > maxPoints else { return records }
        guard maxPoints > 1 else { return [records[records.count - 1]] }
        guard maxPoints > 2 else { return [records.first!, records.last!] }

        let requiredIndices = extremaIndices(in: records)
        guard requiredIndices.count < maxPoints else {
            // When the point budget cannot contain every unique series extremum,
            // endpoints win, followed by charge and then charge-limit extrema.
            return constrainedExtremaIndices(in: records, maxPoints: maxPoints)
                .sorted()
                .map { records[$0] }
        }

        // Reserve enough slots for unique extrema from both plotted series, then
        // use LTTB to distribute the remaining points over the full time range.
        let lttbBudget = max(3, maxPoints - requiredIndices.count + 2)
        var selectedIndices = requiredIndices
        selectedIndices.formUnion(lttbIndices(in: records, threshold: lttbBudget))

        if selectedIndices.count < maxPoints {
            for index in lttbIndices(in: records, threshold: maxPoints)
            where selectedIndices.count < maxPoints {
                selectedIndices.insert(index)
            }
        }
        if selectedIndices.count < maxPoints {
            for index in 1..<(records.count - 1) where selectedIndices.count < maxPoints {
                selectedIndices.insert(index)
            }
        }

        return selectedIndices.sorted().map { records[$0] }
    }

    static func downsampleTimeline(
        _ records: [ChartRecord],
        domainEnd: Date,
        interval: TimeInterval,
        maxPointsPerInterval: Int
    ) -> [ChartRecord] {
        guard interval > 0, maxPointsPerInterval > 0, !records.isEmpty else { return [] }
        let domainStart = domainEnd.addingTimeInterval(-retentionInterval)
        let buckets = Dictionary(grouping: records) { record in
            max(0, Int(record.timestamp.timeIntervalSince(domainStart) / interval))
        }
        return buckets.keys.sorted().flatMap { bucket in
            downsample(buckets[bucket] ?? [], maxPoints: maxPointsPerInterval)
        }
    }

    private static func extremaIndices(in records: [ChartRecord]) -> Set<Int> {
        Set(constrainedExtremaIndices(in: records, maxPoints: 6))
    }

    private static func constrainedExtremaIndices(
        in records: [ChartRecord],
        maxPoints: Int
    ) -> [Int] {
        guard !records.isEmpty, maxPoints > 0 else { return [] }
        guard maxPoints > 1 else { return [records.count - 1] }

        var indices = [0, records.count - 1]
        let candidates = [
            records.indices.max { records[$0].chargePercent < records[$1].chargePercent },
            records.indices.min { records[$0].chargePercent < records[$1].chargePercent },
            records.indices.max { records[$0].chargeLimit < records[$1].chargeLimit },
            records.indices.min { records[$0].chargeLimit < records[$1].chargeLimit }
        ].compactMap { $0 }
        for index in candidates where indices.count < maxPoints && !indices.contains(index) {
            indices.append(index)
        }
        return indices
    }

    private static func lttbIndices(in records: [ChartRecord], threshold: Int) -> [Int] {
        guard threshold < records.count else { return Array(records.indices) }
        guard threshold > 2 else { return [0, records.count - 1] }

        let every = Double(records.count - 2) / Double(threshold - 2)
        var sampled = [0]
        var selectedIndex = 0

        for bucket in 0..<(threshold - 2) {
            let averageStart = min(Int(floor(Double(bucket + 1) * every)) + 1, records.count - 1)
            let averageEnd = min(Int(floor(Double(bucket + 2) * every)) + 1, records.count)
            let averageRange = records[averageStart..<max(averageStart + 1, averageEnd)]
            let averageX = averageRange.map { $0.timestamp.timeIntervalSinceReferenceDate }.reduce(0, +)
                / Double(averageRange.count)
            let averageY = averageRange.map { Double($0.chargePercent) }.reduce(0, +)
                / Double(averageRange.count)
            let averageLimit = averageRange.map { Double($0.chargeLimit) }.reduce(0, +)
                / Double(averageRange.count)

            let rangeStart = min(Int(floor(Double(bucket) * every)) + 1, records.count - 2)
            let rangeEnd = min(Int(floor(Double(bucket + 1) * every)) + 1, records.count - 1)
            let pointA = records[selectedIndex]
            let ax = pointA.timestamp.timeIntervalSinceReferenceDate
            let ay = Double(pointA.chargePercent)
            let limitA = Double(pointA.chargeLimit)
            var bestArea = -1.0
            var bestIndex = rangeStart
            for index in rangeStart..<max(rangeStart + 1, rangeEnd) {
                let point = records[index]
                let chargeArea = abs(
                    (ax - averageX) * (Double(point.chargePercent) - ay)
                    - (ax - point.timestamp.timeIntervalSinceReferenceDate) * (averageY - ay)
                )
                let limitArea = abs(
                    (ax - averageX) * (Double(point.chargeLimit) - limitA)
                    - (ax - point.timestamp.timeIntervalSinceReferenceDate) * (averageLimit - limitA)
                )
                let area = max(chargeArea, limitArea)
                if area > bestArea {
                    bestArea = area
                    bestIndex = index
                }
            }
            sampled.append(bestIndex)
            selectedIndex = bestIndex
        }
        sampled.append(records.count - 1)
        return sampled
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

    private func setReadinessFailure(_ message: String) {
        readiness = .failed(message)
        resolveReadinessWaiters()
        reportDiagnostic(message, operation: "load history store")
    }

    private func resolveReadinessWaiters() {
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        waiters.forEach { $0.resume(returning: readiness) }
    }

    private func reportError(_ message: String, operation: String) {
        if operation == "save history" {
            saveError = message
        } else {
            fetchError = message
        }
        reportDiagnostic(message, operation: operation)
    }

    private func reportDiagnostic(_ message: String, operation: String) {
        logger.error("\(message, privacy: .public)")
        diagnostics.submit(
            DiagnosticEvent(
                category: .history,
                operation: operation,
                outcome: .failed,
                message: message
            )
        )
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
