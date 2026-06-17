import SwiftUI

struct AnalysisView: View {
    let diagnosis: DrainDiagnosis?
    let cycleCount: Int?
    let retentionPct: Double?

    @ObservedObject private var narrative = NarrativeEngine.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                drainCard
                healthCard
                insightsCard
                if narrative.anyAIAvailable {
                    aiSummaryCard
                    aiFindingsCard
                }
            }
            .padding()
        }
        .onAppear { triggerAI() }
    }

    // MARK: - Rule-based cards

    private var drainCard: some View {
        CardView(title: "Current Drain") {
            if let d = diagnosis {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "%.1f W", d.currentWatts))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                            DrainLevelBadge(level: d.level)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            if !d.topAssertors.isEmpty {
                                Text("Sleep prevented by").font(.caption).foregroundColor(.secondary)
                                ForEach(d.topAssertors) { a in
                                    Text(a.processName).font(.caption).fontWeight(.medium)
                                }
                            }
                        }
                    }
                    runtimeRow(d)
                }
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func runtimeRow(_ d: DrainDiagnosis) -> some View {
        let bits: [String] = {
            var b: [String] = []
            if let full = d.estimatedHoursFromFull, full > 0 {
                b.append(String(format: "~%.1f h on a full charge", full))
            }
            if let rem = d.estimatedHoursRemaining, rem > 0 {
                b.append(String(format: "~%.1f h left", rem))
            }
            if let base = d.baselineWatts, base > 0 {
                b.append(String(format: "your 7-day normal: %.1f W", base))
            }
            return b
        }()
        if !bits.isEmpty {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundColor(.secondary)
                Text(bits.joined(separator: "  ·  ")).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var healthCard: some View {
        CardView(title: "Battery Health") {
            HStack(spacing: 24) {
                if let retention = retentionPct {
                    MetricCell(label: "Capacity", value: String(format: "%.0f%%", retention),
                               color: retention >= 80 ? .green : .orange)
                }
                if let cycles = cycleCount {
                    MetricCell(label: "Cycles", value: "\(cycles)",
                               color: cycles < 500 ? .green : cycles < 800 ? .yellow : .orange)
                }
                if retentionPct == nil && cycleCount == nil {
                    Text("Health data not yet available. Keep PowerSleuth running.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private var insightsCard: some View {
        CardView(title: "Findings") {
            if let d = diagnosis {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(d.culprits, id: \.self) { culprit in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: insightIcon(culprit))
                                .foregroundColor(insightColor(culprit)).frame(width: 16)
                            Text(culprit).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Text("Analyzing…").foregroundColor(.secondary)
            }
        }
    }

    // MARK: - AI cards

    private var aiSummaryCard: some View {
        CardView(title: "AI Summary") {
            VStack(alignment: .leading, spacing: 10) {
                if narrative.isGeneratingSummary {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Generating summary…").font(.callout).foregroundColor(.secondary)
                    }
                } else if let result = narrative.summary {
                    Text(result.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        AIProviderBadge(result: result)
                        Spacer()
                        Button("Regenerate") { triggerSummary() }
                            .buttonStyle(.borderless).font(.caption).foregroundColor(.accentColor)
                    }
                } else if let err = narrative.summaryError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                    Button("Retry") { triggerSummary() }.buttonStyle(.borderless).font(.caption)
                } else {
                    Button("Generate Summary") { triggerSummary() }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var aiFindingsCard: some View {
        CardView(title: "AI Findings") {
            VStack(alignment: .leading, spacing: 10) {
                if !narrative.ollamaReady {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundColor(.secondary).font(.caption)
                        Text("For deeper analysis, install Ollama and select a model in Settings.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if narrative.isGeneratingFindings {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(narrative.ollamaReady ? "Running analysis…" : "Generating with Apple Intelligence…")
                            .font(.callout).foregroundColor(.secondary)
                    }
                } else if let result = narrative.findings {
                    Text(result.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        AIProviderBadge(result: result)
                        Spacer()
                        Button("Regenerate") { triggerFindings() }
                            .buttonStyle(.borderless).font(.caption).foregroundColor(.accentColor)
                    }
                } else if let err = narrative.findingsError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                    Button("Retry") { triggerFindings() }.buttonStyle(.borderless).font(.caption)
                } else {
                    Button("Run AI Analysis") { triggerFindings() }.buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Actions

    private func triggerAI() {
        guard narrative.anyAIAvailable, diagnosis != nil else { return }
        if narrative.summary == nil  { triggerSummary() }
        if narrative.findings == nil { triggerFindings() }
    }

    private func triggerSummary() {
        guard let d = diagnosis else { return }
        let metrics = try? DatabaseService.shared.fetchLatestSystemMetrics()
        Task { await narrative.generateSummary(diagnosis: d, metrics: metrics) }
    }

    private func triggerFindings() {
        guard let d = diagnosis else { return }
        let metrics   = try? DatabaseService.shared.fetchLatestSystemMetrics()
        let since     = Date().addingTimeInterval(-3600)
        let processes = (try? DatabaseService.shared.fetchProcessAggregations(since: since, limit: 10)) ?? []
        Task { await narrative.generateFindings(diagnosis: d, metrics: metrics, processes: processes) }
    }

    // MARK: - Helpers

    private func insightIcon(_ text: String) -> String {
        if text.contains("health") || text.contains("capacity") { return "heart.fill" }
        if text.contains("sleep") || text.contains("sleeping")  { return "moon.fill" }
        if text.contains("hot") || text.contains("thermal")     { return "thermometer.medium" }
        if text.contains("Low Power")                           { return "leaf.fill" }
        return "info.circle.fill"
    }

    private func insightColor(_ text: String) -> Color {
        if text.contains("Low Power") || text.contains("normal") { return .green }
        if text.contains("hot") || text.contains("thermal")      { return .red }
        return .orange
    }
}

// MARK: - AI provider badge

struct AIProviderBadge: View {
    let result: AIResult

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: result.provider == .appleIntelligence ? "apple.logo" : "server.rack")
                .font(.caption2)
            Text(result.provider == .appleIntelligence
                 ? "Apple Intelligence"
                 : (result.modelName ?? "Ollama"))
                .font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12))
        .foregroundColor(.accentColor)
        .clipShape(Capsule())
    }
}

// CardView, MetricCell, StatCard, StatRow, DrainLevelBadge → SharedComponents.swift
