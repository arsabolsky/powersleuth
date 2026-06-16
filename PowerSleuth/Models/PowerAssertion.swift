import Foundation
import GRDB

struct PowerAssertion: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var timestamp: Date
    var processName: String
    var assertionType: String  // PreventSystemSleep, PreventDisplaySleep, etc.
    var reasonText: String

    static let databaseTableName = "power_assertions"
}

extension PowerAssertion: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Represents an aggregated view of who's holding assertions over a time window
struct AssertionSummary: Identifiable {
    let id = UUID()
    let processName: String
    let assertionType: String
    let count: Int
}
