import Foundation
import GRDB

// MARK: - Persisted (Tier 2, Deep Power Mode only)

/// System-wide component wattage from `powermetrics` (CPU / GPU / ANE).
struct ComponentPowerSample: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var timestamp: Date
    var cpuWatts: Double
    var gpuWatts: Double
    var aneWatts: Double

    static let databaseTableName = "component_power_samples"
}

extension ComponentPowerSample: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Per-process power signal from `powermetrics --samplers tasks`. GPU ms/s is the key
/// "is this app hammering the GPU" metric (true per-process GPU isn't available otherwise).
struct ProcessPowerSample: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var timestamp: Date
    var pid: Int
    var name: String
    var cpuMsPerSec: Double
    var gpuMsPerSec: Double
    var energyImpact: Double

    static let databaseTableName = "process_power_samples"
}

extension ProcessPowerSample: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ProcessPowerAggregation: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let avgCpuMsPerSec: Double
    let avgGpuMsPerSec: Double
    let avgEnergyImpact: Double
    let sampleCount: Int

    var isGpuHeavy: Bool { avgGpuMsPerSec > 50 }   // >5% of a GPU-second sustained
}

// MARK: - Transient parser output

/// One parsed `powermetrics -f plist` document.
struct DeepPowerSample: Sendable {
    let timestamp: Date
    let cpuWatts: Double
    let gpuWatts: Double
    let aneWatts: Double
    let tasks: [TaskPower]

    struct TaskPower: Sendable {
        let pid: Int
        let name: String
        let cpuMsPerSec: Double
        let gpuMsPerSec: Double
        let energyImpact: Double
    }
}
