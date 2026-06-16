import XCTest
@testable import PowerSleuth

final class ProfileComparisonTests: XCTestCase {

    private func profile(host: String, watts: Double, retention: Double,
                         consumers: [(String, Double)]) -> DeviceProfile {
        DeviceProfile(
            generatedAt: Date(),
            device: .init(model: "Mac", chip: "Apple", logicalCPUs: 8, macOSVersion: "26", hostname: host),
            battery: .init(cycleCount: 100, designCapacityMah: 6000, maxCapacityMah: 5400, retentionPct: retention),
            averageMetrics: .init(avgActiveWatts: watts, avgSleepDrainPctPerHour: 1, avgCpuPct: 10,
                                  avgRamPressurePct: 50, peakWatts: watts * 2, avgLoadAvg: 2,
                                  avgGpuPct: 5, avgVramInUseMb: 500),
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
}
