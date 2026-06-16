import Foundation
import GRDB

final class DatabaseService {
    static let shared = DatabaseService()

    private let dbQueue: DatabaseQueue

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PowerSleuth", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbURL = appSupport.appendingPathComponent("powersleuth.db")

        dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "battery_snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("percentage", .integer)
                t.column("voltageMv", .integer)
                t.column("amperageMa", .integer)
                t.column("temperatureC", .double)
                t.column("isCharging", .boolean)
                t.column("powerSource", .text)
                t.column("thermalState", .integer)
                t.column("lowPowerMode", .boolean)
            }

            try db.create(table: "power_assertions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("processName", .text)
                t.column("assertionType", .text)
                t.column("reasonText", .text)
            }

            try db.create(table: "drain_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startTimestamp", .datetime).notNull()
                t.column("endTimestamp", .datetime)
                t.column("sessionType", .text).notNull()
                t.column("startPercentage", .integer)
                t.column("endPercentage", .integer)
                t.column("avgWatts", .double)
                t.column("drainPctPerHour", .double)
            }

            try db.create(table: "battery_health") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("cycleCount", .integer)
                t.column("designCapacityMah", .integer)
                t.column("maxCapacityMah", .integer)
                t.column("capacityRetentionPct", .double)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Write

    func saveSnapshot(_ snapshot: inout BatterySnapshot) throws {
        try dbQueue.write { db in try snapshot.insert(db) }
    }

    func saveAssertions(_ assertions: [PowerAssertion]) throws {
        try dbQueue.write { db in
            for var a in assertions { try a.insert(db) }
        }
    }

    func openSession(_ session: inout DrainSession) throws {
        try dbQueue.write { db in try session.insert(db) }
    }

    func closeSession(id: Int64, endTimestamp: Date, endPercentage: Int, avgWatts: Double, drainPctPerHour: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE drain_sessions
                SET endTimestamp = ?, endPercentage = ?, avgWatts = ?, drainPctPerHour = ?
                WHERE id = ?
                """,
                arguments: [endTimestamp, endPercentage, avgWatts, drainPctPerHour, id]
            )
        }
    }

    func saveBatteryHealth(cycleCount: Int, designCapacityMah: Int, maxCapacityMah: Int) throws {
        let retention = designCapacityMah > 0
            ? Double(maxCapacityMah) / Double(designCapacityMah) * 100.0
            : 0.0

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO battery_health (timestamp, cycleCount, designCapacityMah, maxCapacityMah, capacityRetentionPct)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [Date(), cycleCount, designCapacityMah, maxCapacityMah, retention]
            )
        }
    }

    // MARK: - Read

    func fetchSnapshots(since date: Date) throws -> [BatterySnapshot] {
        try dbQueue.read { db in
            try BatterySnapshot
                .filter(BatterySnapshot.Columns.timestamp >= date)
                .order(BatterySnapshot.Columns.timestamp)
                .fetchAll(db)
        }
    }

    func fetchRecentSnapshots(minutes: Int) throws -> [BatterySnapshot] {
        try fetchSnapshots(since: Date().addingTimeInterval(-Double(minutes) * 60))
    }

    func fetchAssertions(since date: Date) throws -> [PowerAssertion] {
        try dbQueue.read { db in
            try PowerAssertion
                .filter(Column("timestamp") >= date)
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    func fetchLastSession(type: SessionType) throws -> DrainSession? {
        try dbQueue.read { db in
            try DrainSession
                .filter(Column("sessionType") == type.rawValue)
                .filter(Column("endTimestamp") != nil)
                .order(Column("startTimestamp").desc)
                .fetchOne(db)
        }
    }

    func fetchOpenSession() throws -> DrainSession? {
        try dbQueue.read { db in
            try DrainSession
                .filter(Column("endTimestamp") == nil)
                .order(Column("startTimestamp").desc)
                .fetchOne(db)
        }
    }

    func fetchLatestHealth() throws -> (cycleCount: Int, designMah: Int, maxMah: Int, retentionPct: Double)? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT cycleCount, designCapacityMah, maxCapacityMah, capacityRetentionPct
                FROM battery_health ORDER BY timestamp DESC LIMIT 1
                """)
            guard let row else { return nil }
            return (
                cycleCount: row["cycleCount"] ?? 0,
                designMah: row["designCapacityMah"] ?? 0,
                maxMah: row["maxCapacityMah"] ?? 0,
                retentionPct: row["capacityRetentionPct"] ?? 0
            )
        }
    }

    func medianSleepDrainRate(days: Int) throws -> Double {
        try dbQueue.read { db in
            let rates = try DrainSession
                .filter(Column("sessionType") == SessionType.sleep.rawValue)
                .filter(Column("drainPctPerHour") != nil)
                .filter(Column("startTimestamp") >= Date().addingTimeInterval(-Double(days) * 86400))
                .fetchAll(db)
                .compactMap(\.drainPctPerHour)
                .sorted()

            guard !rates.isEmpty else { return 2.0 }
            let mid = rates.count / 2
            return rates.count % 2 == 0 ? (rates[mid - 1] + rates[mid]) / 2.0 : rates[mid]
        }
    }

    // MARK: - Maintenance

    func pruneOldData() throws {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM battery_snapshots WHERE timestamp < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM power_assertions WHERE timestamp < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM drain_sessions WHERE startTimestamp < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM battery_health WHERE timestamp < ?", arguments: [cutoff])
        }
    }
}
