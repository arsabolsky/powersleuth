import Foundation
import GRDB

struct NetworkSample: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var timestamp: Date
    var processName: String
    var bytesInDelta: Int64
    var bytesOutDelta: Int64
    var retransmits: Int

    static let databaseTableName = "network_samples"

    var totalBytesDelta: Int64 { bytesInDelta + bytesOutDelta }
}

extension NetworkSample: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct NetworkAggregation: Identifiable, Sendable {
    let id = UUID()
    let processName: String
    let totalBytesIn: Int64
    let totalBytesOut: Int64
    let totalRetransmits: Int

    var totalBytes: Int64 { totalBytesIn + totalBytesOut }

    static func format(bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
