import Foundation
import GRDB

struct ProcessSample: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var timestamp: Date
    var pid: Int
    var name: String
    var cpuPct: Double
    var memMb: Double
    var energyImpact: Double   // Activity Monitor "Energy Impact" score
    var state: String          // running / sleeping / stuck / etc.
    var idleWakeups: Double = 0 // idle wake-ups in the sample interval (top "idlew")

    static let databaseTableName = "process_samples"
}

extension ProcessSample: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Aggregated view across multiple samples — used in TopConsumers UI
struct ProcessAggregation: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let avgEnergyImpact: Double
    let maxEnergyImpact: Double
    let avgCpuPct: Double
    let avgMemMb: Double
    let sampleCount: Int
    var avgIdleWakeups: Double = 0

    var impactLevel: ImpactLevel {
        switch avgEnergyImpact {
        case ..<5:   return .low
        case ..<20:  return .moderate
        case ..<60:  return .high
        default:     return .critical
        }
    }
}

enum ImpactLevel: Int, Comparable, Sendable {
    case low, moderate, high, critical

    static func < (lhs: ImpactLevel, rhs: ImpactLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self { case .low: "Low"; case .moderate: "Moderate"; case .high: "High"; case .critical: "Critical" }
    }
}
