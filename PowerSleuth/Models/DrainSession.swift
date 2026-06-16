import Foundation
import GRDB

enum SessionType: String, Codable {
    case awake, sleep
}

struct DrainSession: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var startTimestamp: Date
    var endTimestamp: Date?
    var sessionType: SessionType
    var startPercentage: Int
    var endPercentage: Int?
    var avgWatts: Double?
    var drainPctPerHour: Double?

    static let databaseTableName = "drain_sessions"

    var drainedPercent: Int? {
        guard let end = endPercentage else { return nil }
        return startPercentage - end
    }

    var durationHours: Double? {
        guard let end = endTimestamp else { return nil }
        return end.timeIntervalSince(startTimestamp) / 3600.0
    }

    var isAbnormalSleepDrain: Bool {
        guard sessionType == .sleep, let rate = drainPctPerHour else { return false }
        return rate > 2.0
    }
}

extension DrainSession: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
