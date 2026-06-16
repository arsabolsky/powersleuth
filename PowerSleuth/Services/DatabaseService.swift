import Foundation
import GRDB

final class DatabaseService: Sendable {
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

    var databasePath: String { dbQueue.path }

    // MARK: - Migration

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

        migrator.registerMigration("v2") { db in
            try db.create(table: "process_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("pid", .integer)
                t.column("name", .text).indexed()
                t.column("cpuPct", .double)
                t.column("memMb", .double)
                t.column("energyImpact", .double)
                t.column("state", .text)
            }

            try db.create(table: "system_metrics") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("cpuUserPct", .double)
                t.column("cpuSysPct", .double)
                t.column("cpuIdlePct", .double)
                t.column("ramFreeMb", .integer)
                t.column("ramActiveMb", .integer)
                t.column("ramCompressedMb", .integer)
                t.column("ramWiredMb", .integer)
                t.column("diskReadMbS", .double)
                t.column("diskWriteMbS", .double)
                t.column("systemWatts", .double)
                t.column("adapterWatts", .double)
                t.column("loadAvg1m", .double)
            }

            try db.create(table: "network_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("processName", .text).indexed()
                t.column("bytesInDelta", .integer)
                t.column("bytesOutDelta", .integer)
                t.column("retransmits", .integer)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "battery_snapshots") { t in
                t.add(column: "systemWatts", .double).defaults(to: 0)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Battery Writes

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
            try db.execute(sql: """
                UPDATE drain_sessions
                SET endTimestamp=?, endPercentage=?, avgWatts=?, drainPctPerHour=?
                WHERE id=?
                """, arguments: [endTimestamp, endPercentage, avgWatts, drainPctPerHour, id])
        }
    }

    func saveBatteryHealth(cycleCount: Int, designCapacityMah: Int, maxCapacityMah: Int) throws {
        let retention = designCapacityMah > 0 ? Double(maxCapacityMah) / Double(designCapacityMah) * 100.0 : 0.0
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO battery_health (timestamp,cycleCount,designCapacityMah,maxCapacityMah,capacityRetentionPct)
                VALUES (?,?,?,?,?)
                """, arguments: [Date(), cycleCount, designCapacityMah, maxCapacityMah, retention])
        }
    }

    // MARK: - System Writes

    func saveProcessSamples(_ samples: [ProcessSample]) throws {
        try dbQueue.write { db in
            for var s in samples { try s.insert(db) }
        }
    }

    func saveSystemMetrics(_ metrics: inout SystemMetrics) throws {
        try dbQueue.write { db in try metrics.insert(db) }
    }

    func saveNetworkSamples(_ samples: [NetworkSample]) throws {
        try dbQueue.write { db in
            for var s in samples { try s.insert(db) }
        }
    }

    // MARK: - Battery Reads

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
            try PowerAssertion.filter(Column("timestamp") >= date).order(Column("timestamp")).fetchAll(db)
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
            try DrainSession.filter(Column("endTimestamp") == nil).order(Column("startTimestamp").desc).fetchOne(db)
        }
    }

    func fetchLatestHealth() throws -> (cycleCount: Int, designMah: Int, maxMah: Int, retentionPct: Double)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT cycleCount,designCapacityMah,maxCapacityMah,capacityRetentionPct
                FROM battery_health ORDER BY timestamp DESC LIMIT 1
                """) else { return nil }
            return (row["cycleCount"] ?? 0, row["designCapacityMah"] ?? 0,
                    row["maxCapacityMah"] ?? 0, row["capacityRetentionPct"] ?? 0)
        }
    }

    func medianSleepDrainRate(days: Int) throws -> Double {
        try dbQueue.read { db in
            let rates = try DrainSession
                .filter(Column("sessionType") == SessionType.sleep.rawValue)
                .filter(Column("drainPctPerHour") != nil)
                .filter(Column("startTimestamp") >= Date().addingTimeInterval(-Double(days) * 86400))
                .fetchAll(db).compactMap(\.drainPctPerHour).sorted()
            guard !rates.isEmpty else { return 2.0 }
            let mid = rates.count / 2
            return rates.count % 2 == 0 ? (rates[mid-1] + rates[mid]) / 2 : rates[mid]
        }
    }

    // MARK: - Process Reads

    func fetchProcessAggregations(since date: Date, limit: Int = 30) throws -> [ProcessAggregation] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT name,
                       AVG(energyImpact) as avgEnergy,
                       MAX(energyImpact) as maxEnergy,
                       AVG(cpuPct) as avgCpu,
                       AVG(memMb) as avgMem,
                       COUNT(*) as cnt
                FROM process_samples
                WHERE timestamp >= ? AND energyImpact > 0
                GROUP BY name
                ORDER BY avgEnergy DESC
                LIMIT ?
                """, arguments: [date, limit])
            return rows.map { row in
                ProcessAggregation(
                    name: row["name"] ?? "Unknown",
                    avgEnergyImpact: row["avgEnergy"] ?? 0,
                    maxEnergyImpact: row["maxEnergy"] ?? 0,
                    avgCpuPct: row["avgCpu"] ?? 0,
                    avgMemMb: row["avgMem"] ?? 0,
                    sampleCount: row["cnt"] ?? 0
                )
            }
        }
    }

    func fetchProcessHistory(name: String, since date: Date) throws -> [ProcessSample] {
        try dbQueue.read { db in
            try ProcessSample
                .filter(Column("name") == name)
                .filter(Column("timestamp") >= date)
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    // MARK: - System Metric Reads

    func fetchSystemMetrics(since date: Date) throws -> [SystemMetrics] {
        try dbQueue.read { db in
            try SystemMetrics.filter(Column("timestamp") >= date).order(Column("timestamp")).fetchAll(db)
        }
    }

    func fetchLatestSystemMetrics() throws -> SystemMetrics? {
        try dbQueue.read { db in
            try SystemMetrics.order(Column("timestamp").desc).fetchOne(db)
        }
    }

    func fetchAverageSystemMetrics(since date: Date) throws -> (avgWatts: Double, avgCpu: Double, avgRamPressure: Double, peakWatts: Double)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT AVG(systemWatts), AVG(cpuUserPct+cpuSysPct),
                       AVG(CAST(ramActiveMb+ramWiredMb AS REAL)/(ramFreeMb+ramActiveMb+ramCompressedMb+ramWiredMb)*100),
                       MAX(systemWatts)
                FROM system_metrics WHERE timestamp >= ? AND systemWatts > 0
                """, arguments: [date]) else { return nil }
            return (row[0] ?? 0, row[1] ?? 0, row[2] ?? 0, row[3] ?? 0)
        }
    }

    // MARK: - Network Reads

    func fetchNetworkAggregations(since date: Date, limit: Int = 20) throws -> [NetworkAggregation] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT processName,
                       SUM(bytesInDelta) as totalIn,
                       SUM(bytesOutDelta) as totalOut,
                       SUM(retransmits) as totalRetx
                FROM network_samples
                WHERE timestamp >= ?
                GROUP BY processName
                ORDER BY (totalIn + totalOut) DESC
                LIMIT ?
                """, arguments: [date, limit])
            return rows.map { row in
                NetworkAggregation(
                    processName: row["processName"] ?? "Unknown",
                    totalBytesIn: row["totalIn"] ?? 0,
                    totalBytesOut: row["totalOut"] ?? 0,
                    totalRetransmits: row["totalRetx"] ?? 0
                )
            }
        }
    }

    // MARK: - Profile generation

    func fetchDataAge() throws -> Date? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT MIN(timestamp) FROM system_metrics")
            return row?[0] as? Date
        }
    }

    // MARK: - Maintenance

    func pruneOldData() throws {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        try dbQueue.write { db in
            for table in ["battery_snapshots", "power_assertions", "drain_sessions",
                          "battery_health", "process_samples", "system_metrics", "network_samples"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE timestamp < ?", arguments: [cutoff])
            }
        }
    }
}
