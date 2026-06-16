import Foundation
import GRDB

struct SystemMetrics: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var timestamp: Date
    var cpuUserPct: Double
    var cpuSysPct: Double
    var cpuIdlePct: Double
    var ramFreeMb: Int
    var ramActiveMb: Int
    var ramCompressedMb: Int
    var ramWiredMb: Int
    var diskReadMbS: Double
    var diskWriteMbS: Double
    var systemWatts: Double     // BatteryData.SystemPower — actual measured watts
    var adapterWatts: Double    // BatteryData.AdapterPower
    var loadAvg1m: Double
    var gpuUtilPct: Double = 0  // IOAccelerator "Device Utilization %"
    var vramInUseMb: Double = 0 // IOAccelerator "In use system memory"

    static let databaseTableName = "system_metrics"

    var cpuUsedPct: Double { cpuUserPct + cpuSysPct }
    var ramUsedMb: Int { ramActiveMb + ramWiredMb }
    var ramTotalMb: Int { ramFreeMb + ramActiveMb + ramCompressedMb + ramWiredMb }
    var ramPressurePct: Double {
        guard ramTotalMb > 0 else { return 0 }
        return Double(ramUsedMb) / Double(ramTotalMb) * 100.0
    }
}

extension SystemMetrics: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
