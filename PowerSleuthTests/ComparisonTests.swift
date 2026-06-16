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
        // A draws more watts (worse); A has better battery health (B worse).
        let a = profile(host: "Personal", watts: 12, retention: 95, consumers: [])
        let b = profile(host: "Work", watts: 6, retention: 80, consumers: [])
        let c = ProfileComparison.compare(a, b)

        let power = c.metrics.first { $0.label == "Active power" }!
        XCTAssertEqual(power.worseSide, .a)          // higher watts is worse

        let health = c.metrics.first { $0.label == "Battery health" }!
        XCTAssertEqual(health.worseSide, .b)         // lower retention is worse
    }

    func testMatchedConsumerRatioAndOnlySides() {
        // Both run Slack (different energy); Helium only on A, Chrome only on B.
        let a = profile(host: "Personal", watts: 12, retention: 95,
                        consumers: [("Slack", 20), ("Helium", 40)])
        let b = profile(host: "Work", watts: 6, retention: 95,
                        consumers: [("Slack", 10), ("Google Chrome", 15)])
        let c = ProfileComparison.compare(a, b)

        let slack = c.consumers.first { $0.name == "Slack" }!
        XCTAssertTrue(slack.presentA && slack.presentB)
        XCTAssertEqual(slack.ratio!, 2.0, accuracy: 0.01)   // 20 vs 10

        let helium = c.consumers.first { $0.name == "Helium" }!
        XCTAssertTrue(helium.presentA && !helium.presentB)

        let chrome = c.consumers.first { $0.name == "Google Chrome" }!
        XCTAssertTrue(chrome.presentB && !chrome.presentA)
    }
}

final class DeepPowerParserTests: XCTestCase {

    // Representative powermetrics `-f plist` document (power values in mW).
    private let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>processor</key>
      <dict>
        <key>cpu_power</key><real>2500.0</real>
        <key>gpu_power</key><real>1800.0</real>
        <key>ane_power</key><real>0.0</real>
      </dict>
      <key>tasks</key>
      <array>
        <dict>
          <key>pid</key><integer>501</integer>
          <key>name</key><string>Helium</string>
          <key>cputime_ms_per_s</key><real>120.0</real>
          <key>gputime_ms_per_s</key><real>300.0</real>
          <key>energy_impact</key><real>45.0</real>
        </dict>
        <dict>
          <key>pid</key><integer>88</integer>
          <key>name</key><string>WindowServer</string>
          <key>cputime_ms_per_s</key><real>50.0</real>
          <key>gputime_ms_per_s</key><real>10.0</real>
          <key>energy_impact</key><real>8.0</real>
        </dict>
      </array>
    </dict>
    </plist>
    """

    func testParsesComponentWattsInWatts() {
        let s = DeepPowerSampler.parseDeepPower(Data(plist.utf8))!
        XCTAssertEqual(s.cpuWatts, 2.5, accuracy: 0.001)   // 2500 mW → 2.5 W
        XCTAssertEqual(s.gpuWatts, 1.8, accuracy: 0.001)
        XCTAssertEqual(s.aneWatts, 0.0, accuracy: 0.001)
    }

    func testParsesPerProcessGpuTime() {
        let s = DeepPowerSampler.parseDeepPower(Data(plist.utf8))!
        XCTAssertEqual(s.tasks.count, 2)
        let helium = s.tasks.first { $0.name == "Helium" }!
        XCTAssertEqual(helium.gpuMsPerSec, 300, accuracy: 0.01)
        XCTAssertEqual(helium.cpuMsPerSec, 120, accuracy: 0.01)
        XCTAssertEqual(helium.energyImpact, 45, accuracy: 0.01)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(DeepPowerSampler.parseDeepPower(Data("not a plist".utf8)))
    }
}
