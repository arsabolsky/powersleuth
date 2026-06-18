import Foundation

/// Exportable snapshot for cross-device comparison
struct DeviceProfile: Codable, Sendable {
    let generatedAt: Date
    let device: DeviceInfo
    let battery: BatteryInfo
    let averageMetrics: AverageMetrics
    let topConsumers: [ConsumerSummary]
    let powerAssertionHolders: [String]
    let observations: [String]
    let dataWindowDays: Int
    var backgroundServices: [String]? = nil   // optional → old exported JSON still decodes
    // All optional → profiles exported before these signals existed still decode.
    var wakeStats: WakeStats? = nil
    var networkConsumers: [NetworkConsumerSummary]? = nil
    var componentPower: ComponentPower? = nil
    var sleepStats: SleepStats? = nil

    struct DeviceInfo: Codable, Sendable {
        let model: String
        let chip: String
        let logicalCPUs: Int
        let macOSVersion: String
        let hostname: String
    }

    struct BatteryInfo: Codable, Sendable {
        let cycleCount: Int
        let designCapacityMah: Int
        let maxCapacityMah: Int
        let retentionPct: Double
    }

    struct AverageMetrics: Codable, Sendable {
        let avgActiveWatts: Double
        let avgSleepDrainPctPerHour: Double
        let avgCpuPct: Double
        let avgRamPressurePct: Double
        let peakWatts: Double
        let avgLoadAvg: Double
        // Optional so profiles exported before GPU support still decode.
        var avgGpuPct: Double? = nil
        var avgVramInUseMb: Double? = nil
        // On-battery active-watt percentiles — averages alone hide bimodal (idle vs. busy) behavior.
        var activeWattsP50: Double? = nil
        var activeWattsP90: Double? = nil
    }

    struct ConsumerSummary: Codable, Sendable {
        let name: String
        let avgEnergyImpact: Double
        let avgCpuPct: Double
        let avgMemMb: Double
    }

    /// Overnight/idle wake activity — dark wakes are the usual sleep-drain culprit.
    struct WakeStats: Codable, Sendable {
        let total: Int
        let darkWakes: Int
        let perDay: Double
        let topReasons: [ReasonCount]
        struct ReasonCount: Codable, Sendable { let reason: String; let count: Int }
    }

    struct NetworkConsumerSummary: Codable, Sendable {
        let name: String
        let totalMB: Double
        let retransmits: Int
    }

    /// Measured per-component power (IOReport energy model, no admin required).
    struct ComponentPower: Codable, Sendable {
        let cpuWatts: Double
        let gpuWatts: Double
        let aneWatts: Double
    }

    struct SleepStats: Codable, Sendable {
        let medianDrainPctPerHour: Double
        let sessionCount: Int
    }

    func toJSON(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        return try encoder.encode(self)
    }

    func toMarkdownReport() -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var md = """
        # PowerSleuth Device Report
        Generated: \(df.string(from: generatedAt))
        Data window: \(dataWindowDays) day(s)

        ## Device
        | | |
        |---|---|
        | Model | \(device.model) |
        | Chip | \(device.chip) |
        | CPUs | \(device.logicalCPUs) |
        | macOS | \(device.macOSVersion) |
        | Hostname | \(device.hostname) |

        ## Battery Health
        | | |
        |---|---|
        | Cycle Count | \(battery.cycleCount) |
        | Design Capacity | \(battery.designCapacityMah) mAh |
        | Max Capacity | \(battery.maxCapacityMah) mAh |
        | Health | \(String(format: "%.1f", battery.retentionPct))% |

        ## Average Performance
        | | |
        |---|---|
        | Active Power Draw | \(String(format: "%.1f", averageMetrics.avgActiveWatts)) W |
        | Sleep Drain | \(String(format: "%.2f", averageMetrics.avgSleepDrainPctPerHour)) %/hr |
        | Avg CPU | \(String(format: "%.1f", averageMetrics.avgCpuPct))% |
        | Avg RAM Pressure | \(String(format: "%.1f", averageMetrics.avgRamPressurePct))% |
        | Peak Power Draw | \(String(format: "%.1f", averageMetrics.peakWatts)) W |
        | Avg GPU | \(averageMetrics.avgGpuPct.map { String(format: "%.1f%%", $0) } ?? "—") |
        | Avg VRAM In Use | \(averageMetrics.avgVramInUseMb.map { String(format: "%.0f MB", $0) } ?? "—") |

        ## Top Energy Consumers
        | Process | Energy Impact | CPU% | Memory |
        |---|---|---|---|
        """

        for c in topConsumers.prefix(15) {
            md += "\n| \(c.name) | \(String(format: "%.1f", c.avgEnergyImpact)) | \(String(format: "%.1f", c.avgCpuPct))% | \(String(format: "%.0f", c.avgMemMb)) MB |"
        }

        if averageMetrics.activeWattsP50 != nil || averageMetrics.activeWattsP90 != nil {
            md += "\n\n## On-Battery Power Distribution\n"
            md += "| Median (p50) | \(averageMetrics.activeWattsP50.map { String(format: "%.1f W", $0) } ?? "—") |\n"
            md += "| 90th pct (p90) | \(averageMetrics.activeWattsP90.map { String(format: "%.1f W", $0) } ?? "—") |\n"
        }

        if let cp = componentPower {
            md += "\n\n## Component Power (measured)\n| | |\n|---|---|\n"
            md += "| CPU | \(String(format: "%.2f", cp.cpuWatts)) W |\n"
            md += "| GPU | \(String(format: "%.2f", cp.gpuWatts)) W |\n"
            md += "| ANE | \(String(format: "%.2f", cp.aneWatts)) W |\n"
        }

        if let w = wakeStats {
            md += "\n\n## Wake Activity\n"
            md += "Dark wakes: **\(w.darkWakes)** of \(w.total) total (\(String(format: "%.1f", w.perDay))/day)\n\n"
            if !w.topReasons.isEmpty {
                md += "| Reason | Count |\n|---|---|\n"
                for r in w.topReasons.prefix(8) { md += "| \(r.reason) | \(r.count) |\n" }
            }
        }

        if let consumers = networkConsumers, !consumers.isEmpty {
            md += "\n\n## Top Network Consumers\n| Process | Data | Retransmits |\n|---|---|---|\n"
            for c in consumers.prefix(12) {
                md += "| \(c.name) | \(String(format: "%.1f", c.totalMB)) MB | \(c.retransmits) |\n"
            }
        }

        if let s = sleepStats, s.sessionCount > 0 {
            md += "\n\n## Sleep Sessions\n"
            md += "Median drain: **\(String(format: "%.2f", s.medianDrainPctPerHour)) %/hr** over \(s.sessionCount) session(s)\n"
        }

        if !powerAssertionHolders.isEmpty {
            md += "\n\n## Sleep Prevention\n"
            for h in powerAssertionHolders { md += "- \(h)\n" }
        }

        if !observations.isEmpty {
            md += "\n## Analysis Observations\n"
            for o in observations { md += "- \(o)\n" }
        }

        return md
    }
}
