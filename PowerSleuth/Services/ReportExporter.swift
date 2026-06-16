import Foundation
import IOKit

final class ReportExporter: Sendable {
    static let shared = ReportExporter()
    private init() {}

    func buildDeviceProfile(windowDays: Int = 7) async throws -> DeviceProfile {
        let since = Date().addingTimeInterval(-Double(windowDays) * 86400)
        let db = DatabaseService.shared

        let device  = Self.readDeviceInfo()
        let battery = try buildBatteryInfo(db: db)
        let avg     = try buildAverageMetrics(db: db, since: since)
        let topProc = try db.fetchProcessAggregations(since: since, limit: 15)
        let assertions = try db.fetchAssertions(since: since)
        let observations = try buildObservations(db: db, since: since)

        let assertionHolders = Dictionary(grouping: assertions, by: \.processName)
            .sorted { $0.value.count > $1.value.count }
            .prefix(5)
            .map { "\($0.key) (\($0.value.count) assertions)" }

        return DeviceProfile(
            generatedAt: Date(),
            device: device,
            battery: battery,
            averageMetrics: avg,
            topConsumers: topProc.map { p in
                DeviceProfile.ConsumerSummary(
                    name: p.name,
                    avgEnergyImpact: p.avgEnergyImpact,
                    avgCpuPct: p.avgCpuPct,
                    avgMemMb: p.avgMemMb
                )
            },
            powerAssertionHolders: Array(assertionHolders),
            observations: observations,
            dataWindowDays: windowDays
        )
    }

    private static func readDeviceInfo() -> DeviceProfile.DeviceInfo {
        func sysctl(_ key: String) -> String {
            var size = 0
            sysctlbyname(key, nil, &size, nil, 0)
            guard size > 0 else { return "" }
            var value = [UInt8](repeating: 0, count: size)
            sysctlbyname(key, &value, &size, nil, 0)
            // Drop the trailing NUL before decoding.
            return String(decoding: value.prefix(max(0, size - 1)), as: UTF8.self)
        }
        return DeviceProfile.DeviceInfo(
            model: sysctl("hw.model"),
            chip: sysctl("machdep.cpu.brand_string"),
            logicalCPUs: ProcessInfo.processInfo.processorCount,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
    }

    private func buildBatteryInfo(db: DatabaseService) throws -> DeviceProfile.BatteryInfo {
        if let h = try db.fetchLatestHealth() {
            return DeviceProfile.BatteryInfo(
                cycleCount: h.cycleCount,
                designCapacityMah: h.designMah,
                maxCapacityMah: h.maxMah,
                retentionPct: h.retentionPct
            )
        }
        // Fallback: read live
        if let live = BatteryMonitor.readHealthInfo() {
            let retention = live.designMah > 0 ? Double(live.maxMah) / Double(live.designMah) * 100 : 0
            return DeviceProfile.BatteryInfo(
                cycleCount: live.cycleCount,
                designCapacityMah: live.designMah,
                maxCapacityMah: live.maxMah,
                retentionPct: retention
            )
        }
        return DeviceProfile.BatteryInfo(cycleCount: 0, designCapacityMah: 0, maxCapacityMah: 0, retentionPct: 0)
    }

    private func buildAverageMetrics(db: DatabaseService, since: Date) throws -> DeviceProfile.AverageMetrics {
        let avg = try db.fetchAverageSystemMetrics(since: since)
        let sleepSessions = try db.fetchLastSession(type: .sleep)
        return DeviceProfile.AverageMetrics(
            avgActiveWatts: avg?.avgWatts ?? 0,
            avgSleepDrainPctPerHour: sleepSessions?.drainPctPerHour ?? 0,
            avgCpuPct: avg?.avgCpu ?? 0,
            avgRamPressurePct: avg?.avgRamPressure ?? 0,
            peakWatts: avg?.peakWatts ?? 0,
            avgLoadAvg: 0
        )
    }

    private func buildObservations(db: DatabaseService, since: Date) throws -> [String] {
        var obs: [String] = []
        let diagnosis = AnalysisEngine.shared.analyze(window: 24)
        obs.append(contentsOf: diagnosis.culprits)

        if let dataStart = try db.fetchDataAge() {
            let days = Int(Date().timeIntervalSince(dataStart) / 86400)
            obs.insert("Data collected over \(days) day(s) — \(days >= 7 ? "good baseline" : "more data needed for reliable comparison")", at: 0)
        }
        return obs
    }

    // MARK: - File export helpers

    func exportJSON(_ profile: DeviceProfile) throws -> URL {
        let data = try profile.toJSON()
        let url = exportURL(ext: "json")
        try data.write(to: url)
        return url
    }

    func exportMarkdown(_ profile: DeviceProfile) throws -> URL {
        let md = profile.toMarkdownReport()
        let url = exportURL(ext: "md")
        try md.data(using: .utf8)?.write(to: url)
        return url
    }

    func exportCSV(windowDays: Int = 7) throws -> URL {
        let since = Date().addingTimeInterval(-Double(windowDays) * 86400)
        let metrics = try DatabaseService.shared.fetchSystemMetrics(since: since)
        var csv = "timestamp,systemWatts,cpuPct,ramPressurePct,diskReadMbS,diskWriteMbS\n"
        let fmt = ISO8601DateFormatter()
        for m in metrics {
            csv += "\(fmt.string(from: m.timestamp)),\(m.systemWatts),\(String(format: "%.1f", m.cpuUsedPct)),\(String(format: "%.1f", m.ramPressurePct)),\(String(format: "%.2f", m.diskReadMbS)),\(String(format: "%.2f", m.diskWriteMbS))\n"
        }
        let url = exportURL(ext: "csv")
        try csv.data(using: .utf8)?.write(to: url)
        return url
    }

    /// Exports go to ~/Library/Application Support/PowerSleuth/Exports — unlike the
    /// Desktop, this needs no TCC permission for a non-sandboxed app, so writes never
    /// silently fail. ExportView's "Reveal in Finder" surfaces the file for the user.
    static var exportsDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PowerSleuth/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exportURL(ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let name = "powersleuth-\(formatter.string(from: Date())).\(ext)"
        return Self.exportsDirectory.appendingPathComponent(name)
    }
}
