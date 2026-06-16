import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var batteryMonitor: BatteryMonitor
    @EnvironmentObject var assertionMonitor: AssertionMonitor
    @EnvironmentObject var processSampler: ProcessSampler
    @EnvironmentObject var networkSampler: NetworkSampler
    @EnvironmentObject var systemCollector: SystemMetricsCollector

    @State private var selectedTab = 0
    @State private var diagnosis: DrainDiagnosis?
    @State private var health: (cycleCount: Int, designMah: Int, maxMah: Int, retentionPct: Double)?

    var body: some View {
        NavigationView {
            sidebar
            detailArea
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { refresh() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedTab) {
            Section("Overview") {
                Label("Now",      systemImage: "bolt.fill").tag(0)
                Label("Analysis", systemImage: "lightbulb.fill").tag(1)
            }
            Section("Monitoring") {
                Label("Consumers", systemImage: "chart.bar.fill").tag(2)
                Label("System",    systemImage: "cpu").tag(3)
                Label("History",   systemImage: "chart.line.uptrend.xyaxis").tag(4)
            }
            Section("Tools") {
                Label("Compare",   systemImage: "arrow.left.arrow.right.square").tag(8)
                Label("Export",    systemImage: "square.and.arrow.up").tag(5)
                Label("Help",      systemImage: "questionmark.circle").tag(6)
                Label("Settings",  systemImage: "gear").tag(7)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 180)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailArea: some View {
        switch selectedTab {
        case 0: nowTab
        case 1: AnalysisView(diagnosis: diagnosis, cycleCount: health?.cycleCount, retentionPct: health?.retentionPct)
        case 2: TopConsumersView().environmentObject(processSampler).environmentObject(networkSampler)
        case 3: SystemMetricsView()
        case 4: HistoryChartView()
        case 5: ExportView()
        case 6: HelpView()
        case 7: SettingsView()
        case 8: CompareView()
        default: EmptyView()
        }
    }

    // MARK: - Now Tab

    private var nowTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                powerGauge
                metricsGrid
                assertionsCard
            }
            .padding()
        }
    }

    private var powerGauge: some View {
        HStack(spacing: 24) {
            // Big watts number
            VStack(spacing: 4) {
                if let s = batteryMonitor.currentSnapshot {
                    Text(s.isCharging ? "Charging" : String(format: "%.1f W", s.watts))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(drainColor(s.watts))
                    if !s.isCharging { DrainLevelBadge(level: DrainLevel.from(watts: s.watts)) }
                }
            }

            Divider().frame(height: 60)

            // System watts from BatteryData
            if let m = systemCollector.current, m.systemWatts > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Power").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.1f W", m.systemWatts)).font(.title2).fontWeight(.semibold)
                    Text("measured from battery controller").font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            // Battery % ring
            if let s = batteryMonitor.currentSnapshot {
                ZStack {
                    Circle().stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: Double(s.percentage) / 100.0)
                        .stroke(batteryRingColor(s.percentage), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(s.percentage)%").font(.title3).fontWeight(.bold)
                }
                .frame(width: 72, height: 72)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if let s = batteryMonitor.currentSnapshot {
                StatCard(label: "Temperature",  value: s.temperatureC > 0 ? String(format: "%.1f°C", s.temperatureC) : "—",
                         icon: "thermometer.medium", color: s.temperatureC > 45 ? .red : .orange)
                StatCard(label: "Thermal State", value: thermalLabel(s.thermalState),
                         icon: "flame.fill", color: thermalColor(s.thermalState))
                StatCard(label: "Low Power",     value: s.lowPowerMode ? "On ✓" : "Off",
                         icon: "leaf.fill", color: s.lowPowerMode ? .green : .secondary)
                StatCard(label: "Power Source",  value: s.powerSource.replacingOccurrences(of: " Power", with: ""),
                         icon: "cable.connector", color: .blue)
            }
            if let m = systemCollector.current {
                StatCard(label: "CPU Load",   value: String(format: "%.0f%%", m.cpuUsedPct),
                         icon: "cpu.fill", color: m.cpuUsedPct > 70 ? .red : .blue)
                StatCard(label: "RAM Used",   value: "\(m.ramUsedMb / 1024) GB",
                         icon: "memorychip.fill", color: .purple)
                StatCard(label: "Load Avg",   value: String(format: "%.2f", m.loadAvg1m),
                         icon: "gauge.medium", color: .secondary)
                StatCard(label: "Disk Read",  value: String(format: "%.1f MB/s", m.diskReadMbS),
                         icon: "internaldrive.fill", color: .green)
            }
            if let h = health {
                StatCard(label: "Battery Health",  value: String(format: "%.0f%%", h.retentionPct),
                         icon: "heart.fill", color: h.retentionPct >= 80 ? .green : .orange)
                StatCard(label: "Cycle Count", value: "\(h.cycleCount)",
                         icon: "arrow.clockwise", color: h.cycleCount < 500 ? .green : .orange)
            }
        }
    }

    private var assertionsCard: some View {
        Group {
            if !assertionMonitor.activeAssertions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Sleep Prevention").font(.headline)
                    ForEach(assertionMonitor.activeAssertions) { a in
                        HStack(spacing: 8) {
                            Image(systemName: "moon.zzz.fill").foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.processName).font(.callout).fontWeight(.medium)
                                Text("\(a.assertionType) — \(a.reasonText)")
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Helpers

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let d = AnalysisEngine.shared.analyze()
            let h = try? DatabaseService.shared.fetchLatestHealth()
            DispatchQueue.main.async { self.diagnosis = d; self.health = h }
        }
    }

    private func drainColor(_ watts: Double) -> Color {
        switch DrainLevel.from(watts: watts) {
        case .efficient: return .green
        case .moderate:  return .primary
        case .elevated:  return .orange
        case .heavy:     return .red
        }
    }

    private func batteryRingColor(_ pct: Int) -> Color {
        pct > 50 ? .green : pct > 20 ? .yellow : .red
    }

    private func thermalLabel(_ state: Int) -> String {
        ["Nominal", "Fair", "Serious", "Critical"][safe: state] ?? "Unknown"
    }

    private func thermalColor(_ state: Int) -> Color {
        [Color.green, .yellow, .orange, .red][safe: state] ?? .gray
    }
}

// StatCard, DrainLevelBadge, safe subscript → SharedComponents.swift
