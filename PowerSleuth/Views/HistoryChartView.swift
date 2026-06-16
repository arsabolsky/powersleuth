import SwiftUI
import Charts

enum HistoryWindow: String, CaseIterable {
    case day  = "24h"
    case week = "7d"

    var lookback: TimeInterval {
        switch self {
        case .day:  return 86400
        case .week: return 86400 * 7
        }
    }
}

struct HistoryChartView: View {
    @State private var window: HistoryWindow = .day
    @State private var snapshots: [BatterySnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery History")
                    .font(.title3).bold()
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(HistoryWindow.allCases, id: \.self) { w in
                        Text(w.rawValue).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }

            if snapshots.isEmpty {
                ContentUnavailableView("No Data Yet", systemImage: "chart.line.downtrend.xyaxis",
                    description: Text("Keep PowerSleuth running to build history."))
            } else {
                chartsStack
            }
        }
        .onAppear { loadData() }
        .onChange(of: window) { _ in loadData() }
    }

    private var chartsStack: some View {
        VStack(spacing: 16) {
            // Drain rate (Watts)
            VStack(alignment: .leading, spacing: 4) {
                Text("Power Draw (W)")
                    .font(.caption).foregroundColor(.secondary)
                Chart(snapshots.filter { !$0.isCharging }) { s in
                    LineMark(
                        x: .value("Time", s.timestamp),
                        y: .value("Watts", s.watts)
                    )
                    .foregroundStyle(drainLineColor(watts: s.watts))
                    .interpolationMethod(.catmullRom)
                }
                .frame(height: 100)
                .chartYScale(domain: 0...35)
                .chartXAxis {
                    AxisMarks(values: .stride(by: axisStride)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
            }

            // Battery level (%)
            VStack(alignment: .leading, spacing: 4) {
                Text("Battery Level (%)")
                    .font(.caption).foregroundColor(.secondary)
                Chart(snapshots) { s in
                    AreaMark(
                        x: .value("Time", s.timestamp),
                        y: .value("%", s.percentage)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [.green.opacity(0.4), .green.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    LineMark(
                        x: .value("Time", s.timestamp),
                        y: .value("%", s.percentage)
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)
                }
                .frame(height: 100)
                .chartYScale(domain: 0...100)
            }
        }
    }

    private var axisStride: Calendar.Component {
        window == .day ? .hour : .day
    }

    private func drainLineColor(watts: Double) -> Color {
        switch DrainLevel.from(watts: watts) {
        case .efficient: return .green
        case .moderate:  return .blue
        case .elevated:  return .orange
        case .heavy:     return .red
        }
    }

    private func loadData() {
        DispatchQueue.global(qos: .utility).async {
            let since = Date().addingTimeInterval(-window.lookback)
            let data = (try? DatabaseService.shared.fetchSnapshots(since: since)) ?? []
            DispatchQueue.main.async { snapshots = data }
        }
    }
}
