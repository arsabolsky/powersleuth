import SwiftUI
import Charts

enum ConsumerTimeWindow: String, CaseIterable {
    case hour  = "1h"
    case day   = "24h"
    case week  = "7d"

    var lookback: TimeInterval {
        switch self { case .hour: 3600; case .day: 86400; case .week: 86400 * 7 }
    }
}

struct TopConsumersView: View {
    @EnvironmentObject var processSampler: ProcessSampler
    @EnvironmentObject var networkSampler: NetworkSampler

    @State private var timeWindow: ConsumerTimeWindow = .hour
    @State private var processAggs: [ProcessAggregation] = []
    @State private var networkAggs: [NetworkAggregation] = []
    @State private var sortBy: SortKey = .energyImpact
    @State private var selectedProcess: String? = nil

    enum SortKey: String, CaseIterable {
        case energyImpact = "Energy"
        case cpu           = "CPU"
        case memory        = "Memory"
    }

    var body: some View {
        VSplitView {
            processSection
            if let name = selectedProcess {
                ProcessHistoryView(processName: name)
                    .frame(minHeight: 180)
            }
        }
        .onAppear { loadData() }
        .onChange(of: timeWindow) { _ in loadData() }
    }

    // MARK: - Process section

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Top Energy Consumers")
                    .font(.title3).bold()
                Spacer()
                Picker("Sort", selection: $sortBy) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 200)
                Picker("Window", selection: $timeWindow) {
                    ForEach(ConsumerTimeWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 120)
            }
            .padding([.horizontal, .top])

            if processAggs.isEmpty {
                ContentUnavailableView("Collecting Data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Process sampling starts immediately. Data will appear within 60 seconds."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedProcess) {
                    Section {
                        ForEach(sortedProcesses) { agg in
                            ProcessRow(agg: agg)
                                .tag(agg.name)
                        }
                    } header: {
                        HStack {
                            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Energy").frame(width: 70, alignment: .trailing)
                            Text("CPU").frame(width: 55, alignment: .trailing)
                            Text("Memory").frame(width: 70, alignment: .trailing)
                        }
                        .font(.caption).foregroundColor(.secondary)
                    }

                    if !networkAggs.isEmpty {
                        Section("Network Activity") {
                            ForEach(networkAggs.prefix(10)) { net in
                                NetworkRow(agg: net)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sortedProcesses: [ProcessAggregation] {
        switch sortBy {
        case .energyImpact: processAggs.sorted { $0.avgEnergyImpact > $1.avgEnergyImpact }
        case .cpu:          processAggs.sorted { $0.avgCpuPct > $1.avgCpuPct }
        case .memory:       processAggs.sorted { $0.avgMemMb > $1.avgMemMb }
        }
    }

    private func loadData() {
        DispatchQueue.global(qos: .utility).async {
            let since = Date().addingTimeInterval(-timeWindow.lookback)
            let procs = (try? DatabaseService.shared.fetchProcessAggregations(since: since, limit: 30)) ?? []
            let nets  = (try? DatabaseService.shared.fetchNetworkAggregations(since: since, limit: 15)) ?? []
            DispatchQueue.main.async {
                self.processAggs  = procs
                self.networkAggs  = nets
            }
        }
    }
}

// MARK: - Sub-views

private struct ProcessRow: View {
    let agg: ProcessAggregation

    var body: some View {
        HStack(spacing: 8) {
            ImpactDot(level: agg.impactLevel)
            Text(agg.name)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.0f", agg.avgEnergyImpact))
                .font(.callout.monospacedDigit())
                .foregroundColor(impactColor)
                .frame(width: 70, alignment: .trailing)
            Text(String(format: "%.1f%%", agg.avgCpuPct))
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .trailing)
            Text(String(format: "%.0f MB", agg.avgMemMb))
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var impactColor: Color {
        switch agg.impactLevel {
        case .low:      .secondary
        case .moderate: .primary
        case .high:     .orange
        case .critical: .red
        }
    }
}

private struct NetworkRow: View {
    let agg: NetworkAggregation
    var body: some View {
        HStack {
            Image(systemName: "network").foregroundColor(.blue).frame(width: 20)
            Text(agg.processName).font(.callout).lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ \(NetworkAggregation.format(bytes: agg.totalBytesIn))")
                    .font(.caption.monospacedDigit()).foregroundColor(.green)
                Text("↑ \(NetworkAggregation.format(bytes: agg.totalBytesOut))")
                    .font(.caption.monospacedDigit()).foregroundColor(.blue)
            }
        }
    }
}

private struct ImpactDot: View {
    let level: ImpactLevel
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch level { case .low: .secondary; case .moderate: .green; case .high: .orange; case .critical: .red }
    }
}

// MARK: - Per-process history chart

struct ProcessHistoryView: View {
    let processName: String
    @State private var samples: [ProcessSample] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Energy history: \(processName)")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal)

            if samples.isEmpty {
                Text("No history available yet")
                    .foregroundColor(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Chart(samples) { s in
                    LineMark(x: .value("Time", s.timestamp), y: .value("Energy", s.energyImpact))
                        .foregroundStyle(.orange)
                    AreaMark(x: .value("Time", s.timestamp), y: .value("Energy", s.energyImpact))
                        .foregroundStyle(.orange.opacity(0.15))
                }
                .frame(height: 120)
                .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .onAppear { load() }
        .onChange(of: processName) { _ in load() }
    }

    private func load() {
        DispatchQueue.global(qos: .utility).async {
            let data = (try? DatabaseService.shared.fetchProcessHistory(
                name: processName,
                since: Date().addingTimeInterval(-86400))) ?? []
            DispatchQueue.main.async { samples = data }
        }
    }
}
