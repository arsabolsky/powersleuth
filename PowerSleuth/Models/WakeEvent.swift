import Foundation
import GRDB

/// A wake from sleep, parsed from `pmset -g log`. Dark wakes (background, screen-off) are the
/// usual overnight-drain culprits; full wakes are usually you opening the lid.
struct WakeEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var timestamp: Date
    var type: String     // "DarkWake" or "Wake"
    var reason: String   // categorized: Maintenance, SleepService, Network, User, Bluetooth, ...

    static let databaseTableName = "wake_events"
}

extension WakeEvent: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct WakeSummary: Sendable {
    let total: Int
    let darkWakes: Int
    let byReason: [(reason: String, count: Int)]   // sorted desc
}
