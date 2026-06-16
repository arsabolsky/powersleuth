import SwiftUI

struct AnalysisView: View {
    let diagnosis: DrainDiagnosis?
    let cycleCount: Int?
    let retentionPct: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                drainCard
                healthCard
                insightsCard
            }
            .padding()
        }
    }

    // MARK: - Cards

    private var drainCard: some View {
        CardView(title: "Current Drain") {
            if let d = diagnosis {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f W", d.currentWatts))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        DrainLevelBadge(level: d.level)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if !d.topAssertors.isEmpty {
                            Text("Sleep prevented by")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(d.topAssertors) { a in
                                Text(a.processName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
    }

    private var healthCard: some View {
        CardView(title: "Battery Health") {
            HStack(spacing: 24) {
                if let retention = retentionPct {
                    MetricCell(
                        label: "Capacity",
                        value: String(format: "%.0f%%", retention),
                        color: retention >= 80 ? .green : .orange
                    )
                }
                if let cycles = cycleCount {
                    MetricCell(
                        label: "Cycles",
                        value: "\(cycles)",
                        color: cycles < 500 ? .green : cycles < 800 ? .yellow : .orange
                    )
                }
                if retentionPct == nil && cycleCount == nil {
                    Text("Health data not yet available. Keep PowerSleuth running.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var insightsCard: some View {
        CardView(title: "Why Is Battery Draining?") {
            if let d = diagnosis {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(d.culprits, id: \.self) { culprit in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: insightIcon(culprit))
                                .foregroundColor(insightColor(culprit))
                                .frame(width: 16)
                            Text(culprit)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Text("Analyzing…")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func insightIcon(_ text: String) -> String {
        if text.contains("health") || text.contains("capacity") { return "heart.fill" }
        if text.contains("sleeping") || text.contains("sleep") { return "moon.fill" }
        if text.contains("hot") || text.contains("thermal") { return "thermometer.medium" }
        if text.contains("Low Power") { return "leaf.fill" }
        return "info.circle.fill"
    }

    private func insightColor(_ text: String) -> Color {
        if text.contains("Low Power") { return .green }
        if text.contains("normal") { return .green }
        if text.contains("hot") || text.contains("thermal") { return .red }
        return .orange
    }
}

// CardView, MetricCell, StatCard, StatRow, DrainLevelBadge → SharedComponents.swift
