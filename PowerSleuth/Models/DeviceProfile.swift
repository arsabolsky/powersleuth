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
    }

    struct ConsumerSummary: Codable, Sendable {
        let name: String
        let avgEnergyImpact: Double
        let avgCpuPct: Double
        let avgMemMb: Double
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
