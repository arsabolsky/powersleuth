import SwiftUI

struct MenuBarView: View {
    let onOpenDashboard: () -> Void

    @EnvironmentObject var batteryMonitor: BatteryMonitor
    @EnvironmentObject var assertionMonitor: AssertionMonitor
    @EnvironmentObject var processSampler: ProcessSampler
    @EnvironmentObject var systemCollector: SystemMetricsCollector

    @State private var diagnosis: DrainDiagnosis?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            statsSection
            if !processSampler.topConsumers.isEmpty {
                Divider()
                topConsumersSection
            }
            if !assertionMonitor.activeAssertions.isEmpty {
                Divider()
                assertionsSection
            }
            Divider()
            footerSection
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { refreshDiagnosis() }
        .onChange(of: batteryMonitor.currentSnapshot) { refreshDiagnosis() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PowerSleuth").font(.headline)
                if let d = diagnosis { DrainLevelBadge(level: d.level) }
            }
            Spacer()
            if let s = batteryMonitor.currentSnapshot {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(s.percentage)%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    if s.isCharging {
                        Text("charging").font(.caption2).foregroundColor(.green)
                    } else if s.watts > 0 {
                        Text(String(format: "%.1f W", s.watts))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(drainColor(s.watts))
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var statsSection: some View {
        VStack(spacing: 5) {
            if let s = batteryMonitor.currentSnapshot {
                StatRow(label: "Temp",    value: s.temperatureC > 0 ? String(format: "%.1f°C", s.temperatureC) : "—")
                StatRow(label: "Thermal", value: thermalLabel(s.thermalState))
                if s.lowPowerMode { StatRow(label: "Mode", value: "Low Power ✓") }
            }
            if let m = systemCollector.current {
                StatRow(label: "CPU", value: String(format: "%.0f%%", m.cpuUsedPct))
                StatRow(label: "RAM", value: String(format: "%.0f%% pressure", m.ramPressurePct))
                if m.systemWatts > 0 {
                    StatRow(label: "System", value: String(format: "%.1f W (measured)", m.systemWatts))
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var topConsumersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top Energy Consumers").font(.caption).foregroundColor(.secondary).padding(.top, 4)
            ForEach(processSampler.topConsumers.prefix(4)) { p in
                HStack(spacing: 6) {
                    Circle().fill(impactColor(p.impactLevel)).frame(width: 7, height: 7)
                    Text(p.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f", p.avgEnergyImpact)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    Text(String(format: "%.1f%%", p.avgCpuPct)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var assertionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preventing Sleep").font(.caption).foregroundColor(.secondary).padding(.top, 4)
            ForEach(assertionMonitor.activeAssertions.prefix(3)) { a in
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill").foregroundColor(.orange).font(.caption)
                    Text(a.processName).font(.caption).lineLimit(1)
                    Spacer()
                    Text(a.assertionType.replacingOccurrences(of: "Prevent", with: ""))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var footerSection: some View {
        HStack {
            Button("Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless).font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless).font(.caption).foregroundColor(.secondary)
        }
        .padding(.top, 6)
    }

    // MARK: - Helpers

    private func refreshDiagnosis() {
        DispatchQueue.global(qos: .utility).async {
            let d = AnalysisEngine.shared.analyze()
            DispatchQueue.main.async { self.diagnosis = d }
        }
    }

    private func drainColor(_ watts: Double) -> Color {
        switch DrainLevel.from(watts: watts) {
        case .efficient: .primary
        case .moderate:  .primary
        case .elevated:  .orange
        case .heavy:     .red
        }
    }

    private func thermalLabel(_ state: Int) -> String {
        ["Nominal", "Fair", "Serious", "Critical"][safe: state] ?? "—"
    }

    private func impactColor(_ level: ImpactLevel) -> Color {
        switch level { case .low: .secondary; case .moderate: .green; case .high: .orange; case .critical: .red }
    }
}
