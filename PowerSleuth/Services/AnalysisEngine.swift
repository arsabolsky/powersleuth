import Foundation

final class AnalysisEngine {
    static let shared = AnalysisEngine()
    private init() {}

    func analyze() -> DrainDiagnosis {
        let db = DatabaseService.shared

        let recentSnapshots = (try? db.fetchRecentSnapshots(minutes: 5)) ?? []
        let lastSleepSession = try? db.fetchLastSession(type: .sleep)
        let assertionsLastHour = (try? db.fetchAssertions(since: Date().addingTimeInterval(-3600))) ?? []
        let health = try? db.fetchLatestHealth()
        let medianSleepRate = (try? db.medianSleepDrainRate(days: 30)) ?? 2.0

        // 1. Current watts (average of discharging snapshots in last 5 min)
        let dischargingSnapshots = recentSnapshots.filter { !$0.isCharging }
        let currentWatts: Double
        if dischargingSnapshots.isEmpty {
            currentWatts = 0
        } else {
            currentWatts = dischargingSnapshots.map(\.watts).reduce(0, +) / Double(dischargingSnapshots.count)
        }

        let level = DrainLevel.from(watts: currentWatts)

        // 2. Thermal state from most recent snapshot
        let thermalRaw = recentSnapshots.last?.thermalState ?? 0
        let isThermallyStressed = thermalRaw >= 2  // Serious or Critical

        // 3. Low power mode
        let lowPowerMode = recentSnapshots.last?.lowPowerMode ?? false

        // 4. Sleep drain anomaly
        var sleepDrainAnomalyDesc: String? = nil
        if let session = lastSleepSession,
           let rate = session.drainPctPerHour,
           let hours = session.durationHours,
           hours > 0.1 {
            let threshold = max(2.0, medianSleepRate * 1.5)
            if rate > threshold {
                let rateStr = String(format: "%.1f", rate)
                sleepDrainAnomalyDesc = "Drained \(rateStr)%/hr while sleeping (normal <2%/hr)"
            }
        }

        // 5. Top assertion holders over last hour
        let assertorCounts = Dictionary(grouping: assertionsLastHour, by: { "\($0.processName)|\($0.assertionType)" })
            .map { key, vals -> AssertionSummary in
                let parts = key.split(separator: "|")
                return AssertionSummary(
                    processName: String(parts.first ?? ""),
                    assertionType: String(parts.last ?? ""),
                    count: vals.count
                )
            }
            .sorted { $0.count > $1.count }
        let topAssertors = Array(assertorCounts.prefix(3))

        // 6. Build culprit list (priority order)
        var culprits: [String] = []

        if let h = health, h.retentionPct < 80 {
            let ret = String(format: "%.0f", h.retentionPct)
            culprits.append("Battery at \(ret)% health — reduced capacity limits how long it lasts")
        }

        if let desc = sleepDrainAnomalyDesc {
            if !topAssertors.isEmpty {
                let names = topAssertors.map(\.processName).joined(separator: ", ")
                culprits.append("\(desc). Sleep prevented by: \(names)")
            } else {
                culprits.append(desc)
            }
        }

        if isThermallyStressed {
            let stateNames = ["Nominal", "Fair", "Serious", "Critical"]
            let name = thermalRaw < stateNames.count ? stateNames[thermalRaw] : "Unknown"
            culprits.append("Mac is running hot (\(name) thermal state) — heat increases power draw significantly")
        }

        if lowPowerMode {
            culprits.append("Low Power Mode is active — this is helping extend battery life")
        }

        if culprits.isEmpty && level >= .elevated {
            culprits.append("High active workload — check Activity Monitor's Energy tab to find the top consumer")
        }

        if culprits.isEmpty && level < .elevated {
            culprits.append("Battery drain looks normal for current activity")
        }

        return DrainDiagnosis(
            currentWatts: currentWatts,
            level: level,
            culprits: culprits,
            topAssertors: topAssertors,
            capacityRetentionPct: health?.retentionPct,
            cycleCount: health?.cycleCount
        )
    }
}
