import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var batteryMonitor: BatteryMonitor
    @EnvironmentObject var assertionMonitor: AssertionMonitor
    @State private var showDashboard = false
    @State private var diagnosis: DrainDiagnosis?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            statsSection
            if !topAssertors.isEmpty {
                Divider()
                assertorsSection
            }
            Divider()
            footerSection
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { refreshDiagnosis() }
        .onChange(of: batteryMonitor.currentSnapshot) { _ in refreshDiagnosis() }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PowerSleuth")
                    .font(.headline)
                if let d = diagnosis {
                    DrainLevelBadge(level: d.level)
                }
            }
            Spacer()
            if let s = batteryMonitor.currentSnapshot {
                Text("\(s.percentage)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
            }
        }
        .padding(.bottom, 8)
    }

    private var statsSection: some View {
        VStack(spacing: 6) {
            if let s = batteryMonitor.currentSnapshot {
                StatRow(label: "Draw", value: s.isCharging ? "Charging" : String(format: "%.1f W", s.watts))
                StatRow(label: "Temp", value: s.temperatureC > 0 ? String(format: "%.1f °C", s.temperatureC) : "—")
                StatRow(label: "Source", value: s.powerSource)
                if s.lowPowerMode {
                    StatRow(label: "Mode", value: "Low Power ✓")
                }
            } else {
                Text("Reading battery…")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 8)
    }

    private var assertorsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preventing Sleep")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
            ForEach(topAssertors) { a in
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(a.processName)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(a.assertionType.replacingOccurrences(of: "Prevent", with: ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var footerSection: some View {
        HStack {
            Button("Open Analysis") {
                showDashboard = true
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
        .sheet(isPresented: $showDashboard) {
            DashboardView()
                .environmentObject(batteryMonitor)
                .environmentObject(assertionMonitor)
        }
    }

    // MARK: - Helpers

    private var topAssertors: [AssertionSummary] {
        diagnosis?.topAssertors ?? []
    }

    private func refreshDiagnosis() {
        DispatchQueue.global(qos: .utility).async {
            let d = AnalysisEngine.shared.analyze()
            DispatchQueue.main.async { self.diagnosis = d }
        }
    }
}

// MARK: - Sub-views

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
    }
}

struct DrainLevelBadge: View {
    let level: DrainLevel

    var body: some View {
        Text(level.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.2))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch level {
        case .efficient: return .green
        case .moderate:  return .yellow
        case .elevated:  return .orange
        case .heavy:     return .red
        }
    }
}
