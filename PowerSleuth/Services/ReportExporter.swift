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

        // Enriched signals (best-effort — a missing table/empty window just yields nil).
        let wakeStats = try? buildWakeStats(db: db, since: since, windowDays: windowDays)
        let networkConsumers = try? buildNetworkConsumers(db: db, since: since)
        let componentPower = (try? db.fetchAverageComponentPower(since: since)).flatMap { $0 }.map {
            DeviceProfile.ComponentPower(cpuWatts: $0.cpuW, gpuWatts: $0.gpuW, aneWatts: $0.aneW)
        }
        let sleepStats = (try? db.fetchSleepStats(since: since)).map {
            DeviceProfile.SleepStats(medianDrainPctPerHour: $0.median, sessionCount: $0.count)
        }

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
            dataWindowDays: windowDays,
            backgroundServices: ServicesInventory.capture(),
            wakeStats: wakeStats,
            networkConsumers: networkConsumers,
            componentPower: componentPower,
            sleepStats: sleepStats
        )
    }

    private func buildWakeStats(db: DatabaseService, since: Date, windowDays: Int) throws -> DeviceProfile.WakeStats {
        let w = try db.fetchWakeSummary(since: since)
        let days = max(1.0, Double(windowDays))
        return DeviceProfile.WakeStats(
            total: w.total,
            darkWakes: w.darkWakes,
            perDay: Double(w.total) / days,
            topReasons: w.byReason.prefix(8).map { .init(reason: $0.reason, count: $0.count) }
        )
    }

    private func buildNetworkConsumers(db: DatabaseService, since: Date) throws -> [DeviceProfile.NetworkConsumerSummary] {
        try db.fetchNetworkAggregations(since: since, limit: 12).map {
            DeviceProfile.NetworkConsumerSummary(
                name: $0.processName,
                totalMB: Double($0.totalBytes) / (1024 * 1024),
                retransmits: $0.totalRetransmits
            )
        }
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
        // Active watts must be ON-BATTERY only, else AC samples inflate the comparison.
        let drain = try db.fetchDrainStats(since: since)
        // Percentiles over the on-battery watt distribution — distinguishes "idle most of the
        // time, occasionally busy" from "steadily moderate", which share the same average.
        let wattSamples = (try? db.fetchOnBatteryWattSamples(since: since)) ?? []
        return DeviceProfile.AverageMetrics(
            avgActiveWatts: drain?.avgWatts ?? avg?.avgWatts ?? 0,
            avgSleepDrainPctPerHour: sleepSessions?.drainPctPerHour ?? 0,
            avgCpuPct: avg?.avgCpu ?? 0,
            avgRamPressurePct: avg?.avgRamPressure ?? 0,
            peakWatts: drain?.peakWatts ?? avg?.peakWatts ?? 0,
            avgLoadAvg: 0,
            avgGpuPct: avg?.avgGpu ?? 0,
            avgVramInUseMb: avg?.avgVramMb ?? 0,
            activeWattsP50: wattSamples.isEmpty ? nil : Self.percentile(wattSamples, 0.50),
            activeWattsP90: wattSamples.isEmpty ? nil : Self.percentile(wattSamples, 0.90)
        )
    }

    /// Linear-interpolated percentile of an already-sorted ascending array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
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

    /// Full raw archive: a zip containing a consistent copy of the SQLite DB plus per-table
    /// time-series CSVs. This is the "everything" export for deep offline analysis and real
    /// history — nothing is aggregated away.
    func exportFullArchive(windowDays: Int = 30) throws -> URL {
        let since = Date().addingTimeInterval(-Double(windowDays) * 86400)
        let db = DatabaseService.shared
        let fm = FileManager.default

        // Stage everything in a temp folder, then zip the folder.
        let stamp = fileStamp()
        let stageDir = Self.exportsDirectory.appendingPathComponent("powersleuth-archive-\(stamp)", isDirectory: true)
        try? fm.removeItem(at: stageDir)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        // 1. Consistent copy of the whole database (all tables, full retained history).
        try db.backup(to: stageDir.appendingPathComponent("powersleuth.db"))

        // 2. Convenience CSVs for the time-series tables, scoped to the window.
        try writeSystemMetricsCSV(db: db, since: since, to: stageDir.appendingPathComponent("system_metrics.csv"))
        try writeNetworkCSV(db: db, since: since, to: stageDir.appendingPathComponent("network_samples.csv"))
        try writeWakesCSV(db: db, since: since, to: stageDir.appendingPathComponent("wake_events.csv"))
        try writeSessionsCSV(db: db, since: since, to: stageDir.appendingPathComponent("drain_sessions.csv"))

        // 3. Zip the folder with `ditto` (always present on macOS, preserves structure).
        let zipURL = Self.exportsDirectory.appendingPathComponent("powersleuth-archive-\(stamp).zip")
        try? fm.removeItem(at: zipURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", stageDir.path, zipURL.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "PowerSleuth", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create archive (ditto exit \(proc.terminationStatus))."])
        }
        return zipURL
    }

    private func writeSystemMetricsCSV(db: DatabaseService, since: Date, to url: URL) throws {
        let rows = try db.fetchSystemMetrics(since: since)
        let fmt = ISO8601DateFormatter()
        var csv = "timestamp,systemWatts,adapterWatts,cpuUserPct,cpuSysPct,cpuIdlePct,cpuWatts,gpuWatts,aneWatts,displayWatts,gpuUtilPct,vramInUseMb,ramPressurePct,ramFreeMb,ramActiveMb,ramCompressedMb,ramWiredMb,diskReadMbS,diskWriteMbS,loadAvg1m\n"
        for m in rows {
            csv += "\(fmt.string(from: m.timestamp)),\(m.systemWatts),\(m.adapterWatts),\(m.cpuUserPct),\(m.cpuSysPct),\(m.cpuIdlePct),\(m.cpuWatts),\(m.gpuWatts),\(m.aneWatts),\(m.displayWatts),\(m.gpuUtilPct),\(m.vramInUseMb),\(String(format: "%.1f", m.ramPressurePct)),\(m.ramFreeMb),\(m.ramActiveMb),\(m.ramCompressedMb),\(m.ramWiredMb),\(m.diskReadMbS),\(m.diskWriteMbS),\(m.loadAvg1m)\n"
        }
        try csv.data(using: .utf8)?.write(to: url)
    }

    private func writeNetworkCSV(db: DatabaseService, since: Date, to url: URL) throws {
        let rows = try db.fetchNetworkSamples(since: since)
        let fmt = ISO8601DateFormatter()
        var csv = "timestamp,processName,bytesInDelta,bytesOutDelta,retransmits\n"
        for s in rows {
            csv += "\(fmt.string(from: s.timestamp)),\(csvField(s.processName)),\(s.bytesInDelta),\(s.bytesOutDelta),\(s.retransmits)\n"
        }
        try csv.data(using: .utf8)?.write(to: url)
    }

    private func writeWakesCSV(db: DatabaseService, since: Date, to url: URL) throws {
        let rows = try db.fetchWakeEvents(since: since)
        let fmt = ISO8601DateFormatter()
        var csv = "timestamp,type,reason\n"
        for e in rows {
            csv += "\(fmt.string(from: e.timestamp)),\(csvField(e.type)),\(csvField(e.reason))\n"
        }
        try csv.data(using: .utf8)?.write(to: url)
    }

    private func writeSessionsCSV(db: DatabaseService, since: Date, to url: URL) throws {
        let rows = try db.fetchSessions(since: since)
        let fmt = ISO8601DateFormatter()
        var csv = "startTimestamp,endTimestamp,sessionType,startPercentage,endPercentage,avgWatts,drainPctPerHour\n"
        for s in rows {
            let end = s.endTimestamp.map { fmt.string(from: $0) } ?? ""
            csv += "\(fmt.string(from: s.startTimestamp)),\(end),\(s.sessionType.rawValue),\(s.startPercentage),\(s.endPercentage.map(String.init) ?? ""),\(s.avgWatts.map { String($0) } ?? ""),\(s.drainPctPerHour.map { String($0) } ?? "")\n"
        }
        try csv.data(using: .utf8)?.write(to: url)
    }

    /// Quote a CSV field if it contains a comma, quote, or newline.
    private func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter.string(from: Date())
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
        Self.exportsDirectory.appendingPathComponent("powersleuth-\(fileStamp()).\(ext)")
    }
}
