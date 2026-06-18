import XCTest
@testable import PowerSleuth

final class ProfileComparisonTests: XCTestCase {

    private func profile(host: String, watts: Double, retention: Double,
                         consumers: [(String, Double)], p90: Double? = nil) -> DeviceProfile {
        DeviceProfile(
            generatedAt: Date(),
            device: .init(model: "Mac", chip: "Apple", logicalCPUs: 8, macOSVersion: "26", hostname: host),
            battery: .init(cycleCount: 100, designCapacityMah: 6000, maxCapacityMah: 5400, retentionPct: retention),
            averageMetrics: .init(avgActiveWatts: watts, avgSleepDrainPctPerHour: 1, avgCpuPct: 10,
                                  avgRamPressurePct: 50, peakWatts: watts * 2, avgLoadAvg: 2,
                                  avgGpuPct: 5, avgVramInUseMb: 500, activeWattsP90: p90),
            topConsumers: consumers.map { .init(name: $0.0, avgEnergyImpact: $0.1, avgCpuPct: 1, avgMemMb: 100) },
            powerAssertionHolders: [],
            observations: [],
            dataWindowDays: 7
        )
    }

    func testWorseSideUsesMetricDirection() {
        let a = profile(host: "Personal", watts: 12, retention: 95, consumers: [])
        let b = profile(host: "Work", watts: 6, retention: 80, consumers: [])
        let c = ProfileComparison.compare(a, b)
        XCTAssertEqual(c.metrics.first { $0.label == "Active power" }!.worseSide, .a)   // more watts = worse
        XCTAssertEqual(c.metrics.first { $0.label == "Battery health" }!.worseSide, .b) // lower health = worse
    }

    func testMatchedConsumerRatioAndOnlySides() {
        let a = profile(host: "Personal", watts: 12, retention: 95, consumers: [("Slack", 20), ("Helium", 40)])
        let b = profile(host: "Work", watts: 6, retention: 95, consumers: [("Slack", 10), ("Google Chrome", 15)])
        let c = ProfileComparison.compare(a, b)

        let slack = c.consumers.first { $0.name == "Slack" }!
        XCTAssertEqual(slack.ratio!, 2.0, accuracy: 0.01)
        XCTAssertTrue(c.consumers.first { $0.name == "Helium" }!.presentA)
        XCTAssertFalse(c.consumers.first { $0.name == "Helium" }!.presentB)
        XCTAssertTrue(c.consumers.first { $0.name == "Google Chrome" }!.presentB)
    }

    // MARK: - Enriched signals

    func testEnrichedMetricsOmittedWhenAbsentOnBothProfiles() {
        // Profiles built without the new optional fields must produce the original metric set.
        let a = profile(host: "Personal", watts: 12, retention: 95, consumers: [])
        let b = profile(host: "Work", watts: 6, retention: 95, consumers: [])
        let labels = Set(ProfileComparison.compare(a, b).metrics.map(\.label))
        XCTAssertFalse(labels.contains("Dark wakes/day"))
        XCTAssertFalse(labels.contains("CPU power"))
        XCTAssertFalse(labels.contains("Network total"))
        XCTAssertFalse(labels.contains("90th-pct power (p90)"))
    }

    func testEnrichedMetricsAppearAndScoreWorseSide() {
        // Helper profiles use a 7-day window; compare() derives wakes/day from dataWindowDays.
        let a = withSignals(profile(host: "Personal", watts: 12, retention: 95, consumers: [], p90: 18),
                            darkWakes: 140, cpuW: 4.0)   // 140/7 = 20 dark wakes/day
        let b = withSignals(profile(host: "Work", watts: 6, retention: 95, consumers: [], p90: 9),
                            darkWakes: 14, cpuW: 1.0)    // 14/7  = 2 dark wakes/day
        let c = ProfileComparison.compare(a, b)

        let darkWakes = c.metrics.first { $0.label == "Dark wakes/day" }!
        XCTAssertEqual(darkWakes.valueA, 20, accuracy: 0.01)
        XCTAssertEqual(darkWakes.valueB, 2, accuracy: 0.01)
        XCTAssertEqual(darkWakes.worseSide, .a)  // more wakes = worse
        XCTAssertEqual(c.metrics.first { $0.label == "CPU power" }!.worseSide, .a)
        XCTAssertEqual(c.metrics.first { $0.label == "90th-pct power (p90)" }!.worseSide, .a)
    }

    func testNetworkConsumersMatchedByName() {
        var a = profile(host: "Personal", watts: 12, retention: 95, consumers: [])
        var b = profile(host: "Work", watts: 6, retention: 95, consumers: [])
        a.networkConsumers = [.init(name: "Dropbox", totalMB: 800, retransmits: 5),
                              .init(name: "Slack", totalMB: 100, retransmits: 0)]
        b.networkConsumers = [.init(name: "Slack", totalMB: 50, retransmits: 0)]
        let c = ProfileComparison.compare(a, b)

        let dropbox = c.networkConsumers.first { $0.name == "Dropbox" }!
        XCTAssertTrue(dropbox.presentA)
        XCTAssertFalse(dropbox.presentB)
        // Highest combined-MB consumer sorts first.
        XCTAssertEqual(c.networkConsumers.first?.name, "Dropbox")
        XCTAssertEqual(c.metrics.first { $0.label == "Network total" }!.valueA, 900, accuracy: 0.01)
    }

    func testPercentileInterpolates() {
        let sorted = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(ReportExporter.percentile(sorted, 0.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(ReportExporter.percentile(sorted, 1.0), 4.0, accuracy: 0.001)
        XCTAssertEqual(ReportExporter.percentile(sorted, 0.5), 2.5, accuracy: 0.001)
        XCTAssertEqual(ReportExporter.percentile([], 0.5), 0.0, accuracy: 0.001)
        XCTAssertEqual(ReportExporter.percentile([7.0], 0.9), 7.0, accuracy: 0.001)
    }

    private func withSignals(_ p: DeviceProfile, darkWakes: Int, cpuW: Double) -> DeviceProfile {
        var p = p
        p.wakeStats = .init(total: darkWakes, darkWakes: darkWakes,
                            perDay: Double(darkWakes) / Double(p.dataWindowDays), topReasons: [])
        p.componentPower = .init(cpuWatts: cpuW, gpuWatts: 0, aneWatts: 0)
        return p
    }
}
