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

    /// 차트용 구조체 — Core Data 컨텍스트 밖에서 안전하게 사용
    struct ChartRecord {
        let timestamp: Date
        let chargePercent: Int
        let chargeLimit: Int
    }

    private init() {
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
        model.entities = [entity]

        container = NSPersistentContainer(name: "BatteryGuardHistory", managedObjectModel: model)

        // Application Support에 저장
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent("BatteryGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("BatteryHistory.sqlite")

        let desc = NSPersistentStoreDescription(url: storeURL)
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

    /// 60초마다 호출 — 값이 변경된 경우에만 저장
    func record(chargePercent: Int, chargeLimit: Int) {
        // 변경 없으면 스킵
        if chargePercent == lastChargePercent && chargeLimit == lastChargeLimit {
            return
        }
        lastChargePercent = chargePercent
        lastChargeLimit = chargeLimit

        let ctx = container.newBackgroundContext()
        ctx.perform {
            let record = BatteryRecord(context: ctx)
            record.timestamp = Date()
            record.chargePercent = Int16(chargePercent)
            record.chargeLimit = Int16(chargeLimit)

            // 24시간 초과 데이터 삭제
            let cutoff = Date().addingTimeInterval(-86400)
            let deleteReq = NSFetchRequest<NSFetchRequestResult>(entityName: "BatteryRecord")
            deleteReq.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
            let batchDelete = NSBatchDeleteRequest(fetchRequest: deleteReq)
            try? ctx.execute(batchDelete)

            do {
                try ctx.save()
            } catch {
                print("[BatteryHistory] Save failed: \(error)")
            }
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
