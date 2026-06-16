import Foundation

/// Pure, testable comparison of two exported DeviceProfiles (e.g. personal Mac vs work Mac).
struct ProfileComparison: Sendable {
    let labelA: String
    let labelB: String
    let metrics: [MetricDelta]
    let consumers: [ConsumerDelta]
    let assertionsOnlyA: [String]
    let assertionsOnlyB: [String]
    let assertionsBoth: [String]

    struct MetricDelta: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let unit: String
        let valueA: Double
        let valueB: Double
        let higherIsWorse: Bool

        enum Side: Sendable { case a, b, equal }

        var delta: Double { valueB - valueA }
        var worseSide: Side {
            if abs(valueA - valueB) < 0.0001 { return .equal }
            let aWorse = higherIsWorse ? (valueA > valueB) : (valueA < valueB)
            return aWorse ? .a : .b
        }
    }

    struct ConsumerDelta: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let energyA: Double   // 0 when not present on A
        let energyB: Double
        let presentA: Bool
        let presentB: Bool

        /// Ratio A:B when both present (e.g. Slack draws 2x more on A).
        var ratio: Double? { (energyA > 0 && energyB > 0) ? energyA / energyB : nil }
    }

    // MARK: - Build

    static func compare(_ a: DeviceProfile, _ b: DeviceProfile) -> ProfileComparison {
        let am = a.averageMetrics, bm = b.averageMetrics

        let metrics: [MetricDelta] = [
            MetricDelta(label: "Active power",   unit: "W",    valueA: am.avgActiveWatts, valueB: bm.avgActiveWatts, higherIsWorse: true),
            MetricDelta(label: "Peak power",     unit: "W",    valueA: am.peakWatts, valueB: bm.peakWatts, higherIsWorse: true),
            MetricDelta(label: "Sleep drain",    unit: "%/hr", valueA: am.avgSleepDrainPctPerHour, valueB: bm.avgSleepDrainPctPerHour, higherIsWorse: true),
            MetricDelta(label: "Avg CPU",        unit: "%",    valueA: am.avgCpuPct, valueB: bm.avgCpuPct, higherIsWorse: true),
            MetricDelta(label: "Avg GPU",        unit: "%",    valueA: am.avgGpuPct ?? 0, valueB: bm.avgGpuPct ?? 0, higherIsWorse: true),
            MetricDelta(label: "RAM pressure",   unit: "%",    valueA: am.avgRamPressurePct, valueB: bm.avgRamPressurePct, higherIsWorse: true),
            MetricDelta(label: "Battery health", unit: "%",    valueA: a.battery.retentionPct, valueB: b.battery.retentionPct, higherIsWorse: false),
            MetricDelta(label: "Cycle count",    unit: "",     valueA: Double(a.battery.cycleCount), valueB: Double(b.battery.cycleCount), higherIsWorse: true),
        ]

        // Match consumers by normalized name; unmatched apps appear with one side at 0.
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        var byKeyA: [String: DeviceProfile.ConsumerSummary] = [:]
        for c in a.topConsumers { byKeyA[norm(c.name)] = c }
        var byKeyB: [String: DeviceProfile.ConsumerSummary] = [:]
        for c in b.topConsumers { byKeyB[norm(c.name)] = c }

        let allKeys = Set(byKeyA.keys).union(byKeyB.keys)
        let consumers: [ConsumerDelta] = allKeys.map { key in
            let ca = byKeyA[key]; let cb = byKeyB[key]
            return ConsumerDelta(
                name: ca?.name ?? cb?.name ?? key,
                energyA: ca?.avgEnergyImpact ?? 0,
                energyB: cb?.avgEnergyImpact ?? 0,
                presentA: ca != nil,
                presentB: cb != nil
            )
        }.sorted { max($0.energyA, $0.energyB) > max($1.energyA, $1.energyB) }

        // Assertion holders: strip the " (N assertions)" suffix before set-diffing.
        func holderName(_ s: String) -> String {
            if let r = s.range(of: " (") { return String(s[..<r.lowerBound]) }
            return s
        }
        let holdersA = Set(a.powerAssertionHolders.map(holderName))
        let holdersB = Set(b.powerAssertionHolders.map(holderName))

        return ProfileComparison(
            labelA: label(for: a),
            labelB: label(for: b),
            metrics: metrics,
            consumers: consumers,
            assertionsOnlyA: holdersA.subtracting(holdersB).sorted(),
            assertionsOnlyB: holdersB.subtracting(holdersA).sorted(),
            assertionsBoth: holdersA.intersection(holdersB).sorted()
        )
    }

    private static func label(for p: DeviceProfile) -> String {
        let host = p.device.hostname.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? p.device.model : host
    }
}
