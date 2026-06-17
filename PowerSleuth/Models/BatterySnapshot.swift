import Foundation
import GRDB

struct BatterySnapshot: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var timestamp: Date
    var percentage: Int
    var voltageMv: Int
    var amperageMa: Int        // negative = discharging
    var temperatureC: Double
    var isCharging: Bool
    var powerSource: String    // "AC Power" | "Battery Power"
    var thermalState: Int      // 0=Nominal 1=Fair 2=Serious 3=Critical
    var lowPowerMode: Bool
    var systemWatts: Double    // BatteryData.SystemPower — actual measured watts (0 if unavailable)
    var screenOn: Bool = true  // CGDisplayIsActive — drain means little without knowing this

    static let databaseTableName = "battery_snapshots"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let timestamp = Column(CodingKeys.timestamp)
        static let percentage = Column(CodingKeys.percentage)
        static let voltageMv = Column(CodingKeys.voltageMv)
        static let amperageMa = Column(CodingKeys.amperageMa)
        static let temperatureC = Column(CodingKeys.temperatureC)
        static let isCharging = Column(CodingKeys.isCharging)
        static let powerSource = Column(CodingKeys.powerSource)
        static let thermalState = Column(CodingKeys.thermalState)
        static let lowPowerMode = Column(CodingKeys.lowPowerMode)
        static let systemWatts = Column(CodingKeys.systemWatts)
        static let screenOn = Column(CodingKeys.screenOn)
    }

    /// Real-time power draw in Watts.
    /// When systemWatts is available (from BatteryData.SystemPower), that's the true measurement.
    /// Falls back to mA×mV estimation when not available.
    var watts: Double {
        if systemWatts > 0 { return systemWatts }
        guard !isCharging, voltageMv > 0 else { return 0 }
        return abs(Double(amperageMa) * Double(voltageMv)) / 1_000_000.0
    }
}

extension BatterySnapshot: MutablePersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
