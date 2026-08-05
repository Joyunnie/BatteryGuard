// BatteryHistory.swift
// Core Data 기반 24시간 배터리 이력 저장 + 조회
//
// 60초마다 (chargePercent, chargeLimit)을 기록.
// 24시간 초과 데이터 자동 삭제.
// 프로그래매틱 Core Data 모델 — .xcdatamodeld 파일 불필요.

import Foundation
import CoreData

// MARK: - BatteryRecord (NSManagedObject)

final class BatteryRecord: NSManagedObject {
    @NSManaged var timestamp: Date
    @NSManaged var chargePercent: Int16
    @NSManaged var chargeLimit: Int16
}

// MARK: - BatteryHistory

final class BatteryHistory {
    static let shared = BatteryHistory()

    private let container: NSPersistentContainer
    private let inMemory: Bool

    /// 차트용 구조체 — Core Data 컨텍스트 밖에서 안전하게 사용
    struct ChartRecord {
        let timestamp: Date
        let chargePercent: Int
        let chargeLimit: Int
    }

    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        // 프로그래매틱 모델 정의
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = "BatteryRecord"
        entity.managedObjectClassName = NSStringFromClass(BatteryRecord.self)

        let timestampAttr = NSAttributeDescription()
        timestampAttr.name = "timestamp"
        timestampAttr.attributeType = .dateAttributeType

        let chargePercentAttr = NSAttributeDescription()
        chargePercentAttr.name = "chargePercent"
        chargePercentAttr.attributeType = .integer16AttributeType

        let chargeLimitAttr = NSAttributeDescription()
        chargeLimitAttr.name = "chargeLimit"
        chargeLimitAttr.attributeType = .integer16AttributeType

        entity.properties = [timestampAttr, chargePercentAttr, chargeLimitAttr]

        // Index on timestamp — all queries filter/sort by timestamp
        let timestampIndex = NSFetchIndexDescription(name: "idx_timestamp", elements: [
            NSFetchIndexElementDescription(property: timestampAttr, collationType: .binary)
        ])
        entity.indexes = [timestampIndex]

        model.entities = [entity]

        container = NSPersistentContainer(name: "BatteryGuardHistory", managedObjectModel: model)

        let desc: NSPersistentStoreDescription
        if inMemory {
            desc = NSPersistentStoreDescription()
            desc.type = NSInMemoryStoreType
        } else {
            // Application Support에 저장
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("BatteryGuard", isDirectory: true)
            try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            let storeURL = storeDir.appendingPathComponent("BatteryHistory.sqlite")
            desc = NSPersistentStoreDescription(url: storeURL)
        }
        desc.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        desc.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        container.persistentStoreDescriptions = [desc]

        container.loadPersistentStores { _, error in
            if let error = error {
                print("[BatteryHistory] Core Data load failed: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    // MARK: - 기록

    private var lastChargePercent: Int?
    private var lastChargeLimit: Int?
    private var lastCleanupDate: Date?

    /// 60초마다 호출 — 값이 변경된 경우에만 저장
    func record(chargePercent: Int, chargeLimit: Int) {
        if chargePercent == lastChargePercent && chargeLimit == lastChargeLimit {
            return
        }
        lastChargePercent = chargePercent
        lastChargeLimit = chargeLimit

        // 1시간마다 24시간 초과 데이터 정리
        let needsCleanup: Bool
        if let last = lastCleanupDate {
            needsCleanup = Date().timeIntervalSince(last) >= 3600
        } else {
            needsCleanup = true
        }

        let ctx = container.newBackgroundContext()
        ctx.perform {
            let record = BatteryRecord(context: ctx)
            record.timestamp = Date()
            record.chargePercent = Int16(chargePercent)
            record.chargeLimit = Int16(chargeLimit)

            if needsCleanup {
                let cutoff = Date().addingTimeInterval(-86400)
                if self.inMemory {
                    // NSInMemoryStoreType does not support NSBatchDeleteRequest.
                    let fetch = NSFetchRequest<BatteryRecord>(entityName: "BatteryRecord")
                    fetch.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
                    if let expired = try? ctx.fetch(fetch) {
                        expired.forEach(ctx.delete)
                    }
                } else {
                    let deleteReq = NSFetchRequest<NSFetchRequestResult>(entityName: "BatteryRecord")
                    deleteReq.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
                    let batchDelete = NSBatchDeleteRequest(fetchRequest: deleteReq)
                    batchDelete.resultType = .resultTypeObjectIDs
                    if let result = try? ctx.execute(batchDelete) as? NSBatchDeleteResult,
                       let ids = result.result as? [NSManagedObjectID], !ids.isEmpty {
                        NSManagedObjectContext.mergeChanges(
                            fromRemoteContextSave: [NSDeletedObjectsKey: ids],
                            into: [self.container.viewContext]
                        )
                    }
                }
            }

            do {
                try ctx.save()
            } catch {
                print("[BatteryHistory] Save failed: \(error)")
            }
        }

        if needsCleanup {
            lastCleanupDate = Date()
        }
    }

    // MARK: - 조회

    /// 최근 24시간 데이터를 메인 스레드에서 조회
    func fetchLast24Hours() -> [ChartRecord] {
        let ctx = container.viewContext
        let req = NSFetchRequest<BatteryRecord>(entityName: "BatteryRecord")
        req.predicate = NSPredicate(format: "timestamp >= %@", Date().addingTimeInterval(-86400) as NSDate)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let records = try ctx.fetch(req)
            return records.map {
                ChartRecord(
                    timestamp: $0.timestamp,
                    chargePercent: Int($0.chargePercent),
                    chargeLimit: Int($0.chargeLimit)
                )
            }
        } catch {
            print("[BatteryHistory] Fetch failed: \(error)")
            return []
        }
    }
}
