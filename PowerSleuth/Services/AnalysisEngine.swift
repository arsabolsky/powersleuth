import Foundation

final class AnalysisEngine: Sendable {
    static let shared = AnalysisEngine()
    private init() {}

    func analyze(window hours: Int = 1) -> DrainDiagnosis {
        let db = DatabaseService.shared
        let since = Date().addingTimeInterval(-Double(hours) * 3600)

        let recentSnapshots     = (try? db.fetchRecentSnapshots(minutes: 5)) ?? []
        let lastSleepSession    = try? db.fetchLastSession(type: .sleep)
        let assertionsLastHour  = (try? db.fetchAssertions(since: since)) ?? []
        let health              = try? db.fetchLatestHealth()
        let medianSleepRate     = (try? db.medianSleepDrainRate(days: 30)) ?? 2.0
        let processAggs         = (try? db.fetchProcessAggregations(since: since, limit: 10)) ?? []
        let latestMetrics       = try? db.fetchLatestSystemMetrics()

        // 1. Current watts — prefer measured SystemPower over estimate
        let dischargingSnaps = recentSnapshots.filter { !$0.isCharging }
        let currentWatts: Double = {
            let systemWatts = dischargingSnaps.compactMap { $0.systemWatts > 0 ? $0.systemWatts : nil }
            if !systemWatts.isEmpty { return systemWatts.reduce(0, +) / Double(systemWatts.count) }
            let estimated = dischargingSnaps.map(\.watts).filter { $0 > 0 }
            return estimated.isEmpty ? 0 : estimated.reduce(0, +) / Double(estimated.count)
        }()

        let level = DrainLevel.from(watts: currentWatts)

        // 2. Thermal state
        let thermalRaw = recentSnapshots.last?.thermalState ?? 0
        let thermallyStressed = thermalRaw >= 2

        // 3. Low power mode
        let lowPowerMode = recentSnapshots.last?.lowPowerMode ?? false

        // 4. Sleep drain anomaly
        var sleepAnomalyDesc: String?
        if let session = lastSleepSession,
           let rate = session.drainPctPerHour,
           let hrs = session.durationHours, hrs > 0.1 {
            if rate > max(2.0, medianSleepRate * 1.5) {
                sleepAnomalyDesc = String(format: "Drained %.1f%%/hr while sleeping (normal <2%%/hr)", rate)
            }
        }

        // 5. Top assertion holders
        let assertorCounts = Dictionary(grouping: assertionsLastHour, by: {
                "\($0.processName)|\($0.assertionType)"
            })
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

        // 6. Top energy consumers from process sampler
        let topProcess = processAggs.first
        let highImpactProcesses = processAggs.filter { $0.impactLevel >= .high }

        // 7. System metrics context
        let cpuPct = latestMetrics?.cpuUsedPct ?? 0
        let ramPressure = latestMetrics?.ramPressurePct ?? 0
        // Windowed GPU average (falls back to the latest sample).
        let avgGpu = (try? db.fetchAverageSystemMetrics(since: since))?.avgGpu ?? 0
        let gpuPct = max(avgGpu, latestMetrics?.gpuUtilPct ?? 0)

        // 8. Build culprit list (priority order)
        var culprits: [String] = []

        if let h = health, h.retentionPct < 80 {
            culprits.append(String(format: "Battery health at %.0f%% — reduced capacity is shrinking your range", h.retentionPct))
        }

        if !highImpactProcesses.isEmpty {
            let names = highImpactProcesses.prefix(3).map(\.name).joined(separator: ", ")
            let topImpact = highImpactProcesses[0].avgEnergyImpact
            culprits.append(String(format: "High-impact processes: %@ (top score: %.0f)", names, topImpact))
        } else if let top = topProcess, top.avgEnergyImpact > 5 {
            culprits.append(String(format: "Top energy consumer: %@ (impact %.0f, CPU %.1f%%)",
                                   top.name, top.avgEnergyImpact, top.avgCpuPct))
        }

        if let desc = sleepAnomalyDesc {
            if !topAssertors.isEmpty {
                let names = topAssertors.map(\.processName).joined(separator: ", ")
                culprits.append("\(desc). Sleep prevented by: \(names)")
            } else {
                culprits.append(desc)
            }
        }

        if thermallyStressed {
            let labels = ["Nominal", "Fair", "Serious", "Critical"]
            let label = thermalRaw < labels.count ? labels[thermalRaw] : "Unknown"
            culprits.append("Mac running hot (\(label)) — sustained heat forces higher power draw")
        }

        if cpuPct > 50 {
            culprits.append(String(format: "High system CPU load: %.0f%% — active work is the drain source", cpuPct))
        }

        // Prefer measured per-process GPU (Deep Power Mode) over inference when available.
        let deepGpuHeavy: [ProcessPowerAggregation] = {
            guard (try? db.hasProcessPower(since: since)) == true else { return [] }
            return ((try? db.fetchProcessPowerAggregations(since: since, limit: 5)) ?? []).filter { $0.isGpuHeavy }
        }()

        if let top = deepGpuHeavy.first {
            culprits.append(String(format: "GPU-heavy app: %@ — %.0f ms/s of GPU time (measured). Sustained GPU work is energy-dense.", top.name, top.avgGpuMsPerSec))
        } else if gpuPct > 40 {
            // Per-process GPU isn't available without admin, so name the likely app by inference.
            let suspect = highImpactProcesses.first?.name ?? topProcess?.name
            if let s = suspect {
                culprits.append(String(format: "GPU utilization %.0f%% — likely driven by %@ (enable Deep Power Mode for true per-app GPU watts)", gpuPct, s))
            } else {
                culprits.append(String(format: "Sustained GPU utilization %.0f%% — GPU-dense work is adding drain", gpuPct))
            }
        }

        if ramPressure > 80 {
            culprits.append(String(format: "Memory pressure at %.0f%% — compressor and swap activity adds drain", ramPressure))
        }

        if lowPowerMode {
            culprits.append("Low Power Mode active — this is reducing drain by ~20–30%")
        }

        if culprits.isEmpty && level >= .elevated {
            culprits.append("Elevated drain with no single obvious culprit — check the Top Consumers tab for details")
        }

        if culprits.isEmpty {
            culprits.append("Battery drain looks normal for current activity level")
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
