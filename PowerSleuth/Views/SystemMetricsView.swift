import SwiftUI
import Charts

struct SystemMetricsView: View {
    @State private var metrics: [SystemMetrics] = []
    @State private var window: HistoryWindow = .day
    @State private var current: SystemMetrics?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                windowPicker
                liveStatsGrid
                powerChart
                cpuChart
                ramChart
                diskChart
            }
            .padding()
        }
        .onAppear { loadData() }
        .onChange(of: window) { _ in loadData() }
    }

    // MARK: - Picker

    private var windowPicker: some View {
        HStack {
            Text("System Metrics").font(.title3).bold()
            Spacer()
            Picker("Window", selection: $window) {
                ForEach(HistoryWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 100)
        }
    }

    // MARK: - Live stat grid

    private var liveStatsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if let m = current {
                MiniMetric(label: "System Power", value: String(format: "%.1f W", m.systemWatts),
                           icon: "bolt.fill", color: drainLevelColor(m.systemWatts))
                MiniMetric(label: "CPU Load", value: String(format: "%.0f%%", m.cpuUsedPct),
                           icon: "cpu.fill", color: cpuColor(m.cpuUsedPct))
                MiniMetric(label: "RAM Pressure", value: String(format: "%.0f%%", m.ramPressurePct),
                           icon: "memorychip.fill", color: ramColor(m.ramPressurePct))
                MiniMetric(label: "Load Avg", value: String(format: "%.2f", m.loadAvg1m),
                           icon: "gauge.medium", color: .secondary)
            }
        }
    }

    // MARK: - Charts

    private var powerChart: some View {
        ChartCard(title: "System Power Draw (W)") {
            Chart(metrics.filter { $0.systemWatts > 0 }) { m in
                LineMark(x: .value("t", m.timestamp), y: .value("W", m.systemWatts))
                    .foregroundStyle(drainLevelColor(m.systemWatts))
                AreaMark(x: .value("t", m.timestamp), y: .value("W", m.systemWatts))
                    .foregroundStyle(drainLevelColor(m.systemWatts).opacity(0.15))
            }
            .chartYScale(domain: 0...40)
            .chartXAxis { AxisMarks(values: .stride(by: axisStride)) { _ in AxisGridLine(); AxisValueLabel(format: axisFormat) } }
        }
    }

    private var cpuChart: some View {
        ChartCard(title: "CPU Usage (%)") {
            Chart(metrics) { m in
                AreaMark(x: .value("t", m.timestamp), y: .value("user", m.cpuUserPct))
                    .foregroundStyle(.blue.opacity(0.6))
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("t", m.timestamp), y: .value("sys", m.cpuSysPct))
                    .foregroundStyle(.purple.opacity(0.4))
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartForegroundStyleScale(["User": Color.blue, "System": Color.purple])
            .chartXAxis { AxisMarks(values: .stride(by: axisStride)) { _ in AxisGridLine(); AxisValueLabel(format: axisFormat) } }
        }
    }

    private var ramChart: some View {
        ChartCard(title: "Memory Pressure (%)") {
            Chart(metrics) { m in
                LineMark(x: .value("t", m.timestamp), y: .value("%", m.ramPressurePct))
                    .foregroundStyle(ramColor(m.ramPressurePct))
                    .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .stride(by: axisStride)) { _ in AxisGridLine(); AxisValueLabel(format: axisFormat) } }
        }
    }

    private var diskChart: some View {
        ChartCard(title: "Disk I/O (MB/s)") {
            Chart(metrics) { m in
                LineMark(x: .value("t", m.timestamp), y: .value("read", m.diskReadMbS))
                    .foregroundStyle(.green).interpolationMethod(.catmullRom)
                LineMark(x: .value("t", m.timestamp), y: .value("write", m.diskWriteMbS))
                    .foregroundStyle(.orange).interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(["Read": Color.green, "Write": Color.orange])
            .chartXAxis { AxisMarks(values: .stride(by: axisStride)) { _ in AxisGridLine(); AxisValueLabel(format: axisFormat) } }
        }
    }

    // MARK: - Helpers

    private var axisStride: Calendar.Component { window == .day ? .hour : .day }
    private var axisFormat: Date.FormatStyle { window == .day ? .dateTime.hour() : .dateTime.weekday() }

    private func drainLevelColor(_ watts: Double) -> Color {
        switch DrainLevel.from(watts: watts) {
        case .efficient: return .green
        case .moderate:  return .blue
        case .elevated:  return .orange
        case .heavy:     return .red
        }
    }
    private func cpuColor(_ pct: Double) -> Color { pct > 70 ? .red : pct > 40 ? .orange : .blue }
    private func ramColor(_ pct: Double) -> Color { pct > 80 ? .red : pct > 60 ? .orange : .purple }

    private func loadData() {
        let since = Date().addingTimeInterval(-window.lookback)
        DispatchQueue.global(qos: .utility).async {
            let data    = (try? DatabaseService.shared.fetchSystemMetrics(since: since)) ?? []
            let latest  = try? DatabaseService.shared.fetchLatestSystemMetrics()
            DispatchQueue.main.async {
                self.metrics = data
                self.current = latest
            }
        }
    }
}

// MARK: - ChartCard & MiniMetric

struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content().frame(height: 110)
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct MiniMetric: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundColor(color).font(.caption)
                Text(label).font(.caption).foregroundColor(.secondary)
            }
            Text(value).font(.title3).fontWeight(.semibold).foregroundColor(color)
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }
}
