import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var batteryMonitor: BatteryMonitor
    @EnvironmentObject var assertionMonitor: AssertionMonitor
    @State private var selectedTab: Int = 0
    @State private var diagnosis: DrainDiagnosis?
    @State private var health: (cycleCount: Int, designMah: Int, maxMah: Int, retentionPct: Double)?

    var body: some View {
        TabView(selection: $selectedTab) {
            nowTab.tabItem { Label("Now", systemImage: "bolt.fill") }.tag(0)
            HistoryChartView().tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }.tag(1)
            analysisTab.tabItem { Label("Analysis", systemImage: "magnifyingglass") }.tag(2)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { refresh() }
    }

    // MARK: - Now Tab

    private var nowTab: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                if let s = batteryMonitor.currentSnapshot {
                    StatCard(label: "Battery",    value: "\(s.percentage)%",           icon: "battery.75",          color: .green)
                    StatCard(label: "Power Draw", value: s.isCharging ? "Charging" : String(format: "%.1f W", s.watts),
                             icon: "bolt.fill", color: s.isCharging ? .green : drainColor(s.watts))
                    StatCard(label: "Temperature", value: s.temperatureC > 0 ? String(format: "%.1f °C", s.temperatureC) : "—",
                             icon: "thermometer.medium", color: .orange)
                    StatCard(label: "Source", value: s.powerSource.replacingOccurrences(of: " Power", with: ""),
                             icon: s.isCharging ? "cable.connector" : "battery.100", color: .blue)
                    StatCard(label: "Thermal State", value: thermalLabel(s.thermalState),
                             icon: "flame.fill", color: thermalColor(s.thermalState))
                    StatCard(label: "Low Power", value: s.lowPowerMode ? "On" : "Off",
                             icon: "leaf.fill", color: s.lowPowerMode ? .green : .secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .gridCellColumns(2)
                }
            }
            .padding()

            if !assertionMonitor.activeAssertions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Power Assertions")
                        .font(.headline)
                        .padding(.horizontal)
                    ForEach(assertionMonitor.activeAssertions) { a in
                        HStack {
                            Image(systemName: "moon.zzz.fill").foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.processName).font(.callout).fontWeight(.medium)
                                Text(a.assertionType).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(a.reasonText).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom)
            }
        }
    }

    // MARK: - Analysis Tab

    private var analysisTab: some View {
        AnalysisView(
            diagnosis: diagnosis,
            cycleCount: health?.cycleCount,
            retentionPct: health?.retentionPct
        )
    }

    // MARK: - Helpers

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let d = AnalysisEngine.shared.analyze()
            let h = try? DatabaseService.shared.fetchLatestHealth()
            DispatchQueue.main.async {
                self.diagnosis = d
                self.health = h
            }
        }
    }

    private func drainColor(_ watts: Double) -> Color {
        switch DrainLevel.from(watts: watts) {
        case .efficient: return .green
        case .moderate:  return .blue
        case .elevated:  return .orange
        case .heavy:     return .red
        }
    }

    private func thermalLabel(_ state: Int) -> String {
        ["Nominal", "Fair", "Serious", "Critical"][safe: state] ?? "Unknown"
    }

    private func thermalColor(_ state: Int) -> Color {
        [Color.green, .yellow, .orange, .red][safe: state] ?? .gray
    }
}

// MARK: - StatCard

struct StatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Text(label).font(.caption).foregroundColor(.secondary)
            }
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
