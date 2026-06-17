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

        migrator.registerMigration("v4") { db in
            try db.alter(table: "system_metrics") { t in
                t.add(column: "gpuUtilPct", .double).defaults(to: 0)
                t.add(column: "vramInUseMb", .double).defaults(to: 0)
            }
        }

        // Tier 2 (Deep Power Mode): separate tables so the powermetrics cadence never
        // pollutes the always-on Tier 1 system_metrics averages.
        migrator.registerMigration("v5") { db in
            try db.create(table: "component_power_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("cpuWatts", .double)
                t.column("gpuWatts", .double)
                t.column("aneWatts", .double)
            }
            try db.create(table: "process_power_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("pid", .integer)
                t.column("name", .text).indexed()
                t.column("cpuMsPerSec", .double)
                t.column("gpuMsPerSec", .double)
                t.column("energyImpact", .double)
            }
        }

        // Deep Power Mode (admin powermetrics) was replaced by always-on IOReport: fold
        // component watts into system_metrics and drop the Tier-2 tables.
        migrator.registerMigration("v6") { db in
            try db.alter(table: "system_metrics") { t in
                t.add(column: "cpuWatts", .double).defaults(to: 0)
                t.add(column: "gpuWatts", .double).defaults(to: 0)
                t.add(column: "aneWatts", .double).defaults(to: 0)
            }
            try db.drop(table: "process_power_samples")
            try db.drop(table: "component_power_samples")
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "system_metrics") { t in
                t.add(column: "displayWatts", .double).defaults(to: 0)
            }
            try db.alter(table: "process_samples") { t in
                t.add(column: "idleWakeups", .double).defaults(to: 0)
            }
            try db.create(table: "wake_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("type", .text)
                t.column("reason", .text)
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
            for a in assertions { try a.insert(db) }
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
            for s in samples { try s.insert(db) }
        }
    }

    func saveSystemMetrics(_ metrics: inout SystemMetrics) throws {
        try dbQueue.write { db in try metrics.insert(db) }
    }

    func saveNetworkSamples(_ samples: [NetworkSample]) throws {
        try dbQueue.write { db in
            for s in samples { try s.insert(db) }
        }
    }

    // MARK: - Wake events (pmset -g log)

    /// Inserts only wake events newer than the most recent stored one (pmset log is re-parsed
    /// periodically, so this avoids duplicates).
    func saveWakeEvents(_ events: [WakeEvent]) throws {
        try dbQueue.write { db in
            // ORM fetch is NULL-safe (MAX(timestamp) on an empty table is NULL and would
            // throw when decoded as a non-optional Date).
            let latest = try WakeEvent.order(Column("timestamp").desc).fetchOne(db)?.timestamp
            for var e in events where latest == nil || e.timestamp > latest! {
                try e.insert(db)
            }
        }
    }

    func fetchWakeSummary(since date: Date) throws -> WakeSummary {
        try dbQueue.read { db in
            let events = try WakeEvent.filter(Column("timestamp") >= date).fetchAll(db)
            let dark = events.filter { $0.type == "DarkWake" }.count
            let grouped = Dictionary(grouping: events, by: \.reason)
                .map { (reason: $0.key, count: $0.value.count) }
                .sorted { $0.count > $1.count }
            return WakeSummary(total: events.count, darkWakes: dark, byReason: grouped)
        }
    }

    // MARK: - Component power (IOReport, always-on, no admin)

    /// Average measured CPU/GPU/ANE watts over the window. nil if no samples carry power.
    func fetchAverageComponentPower(since date: Date) throws -> (cpuW: Double, gpuW: Double, aneW: Double)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT AVG(cpuWatts), AVG(gpuWatts), AVG(aneWatts), COUNT(*)
                FROM system_metrics WHERE timestamp >= ? AND (cpuWatts > 0 OR gpuWatts > 0)
                """, arguments: [date]), (row[3] ?? 0) > 0 else { return nil }
            return (row[0] ?? 0, row[1] ?? 0, row[2] ?? 0)
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
                       AVG(idleWakeups) as avgWakeups,
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
                    sampleCount: row["cnt"] ?? 0,
                    avgIdleWakeups: row["avgWakeups"] ?? 0
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

    func fetchAverageSystemMetrics(since date: Date) throws -> (avgWatts: Double, avgCpu: Double, avgRamPressure: Double, peakWatts: Double, avgGpu: Double, avgVramMb: Double)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT AVG(systemWatts), AVG(cpuUserPct+cpuSysPct),
                       AVG(CAST(ramActiveMb+ramWiredMb AS REAL)/(ramFreeMb+ramActiveMb+ramCompressedMb+ramWiredMb)*100),
                       MAX(systemWatts), AVG(gpuUtilPct), AVG(vramInUseMb)
                FROM system_metrics WHERE timestamp >= ? AND systemWatts > 0
                """, arguments: [date]) else { return nil }
            return (row[0] ?? 0, row[1] ?? 0, row[2] ?? 0, row[3] ?? 0, row[4] ?? 0, row[5] ?? 0)
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
            try SystemMetrics.order(Column("timestamp")).fetchOne(db)?.timestamp
        }
    }

    // MARK: - Maintenance

    func pruneOldData(retentionDays: Int = 30) throws {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        try dbQueue.write { db in
            // Most tables key off `timestamp`; drain_sessions keys off `startTimestamp`.
            for table in ["battery_snapshots", "power_assertions",
                          "battery_health", "process_samples", "system_metrics", "network_samples",
                          "wake_events"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE timestamp < ?", arguments: [cutoff])
            }
            try db.execute(sql: "DELETE FROM drain_sessions WHERE startTimestamp < ?", arguments: [cutoff])
        }
    }
}
