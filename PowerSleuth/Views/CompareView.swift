import SwiftUI
import UniformTypeIdentifiers

struct CompareView: View {
    @ObservedObject private var narrative = NarrativeEngine.shared

    @State private var profileA: DeviceProfile?
    @State private var profileB: DeviceProfile?
    @State private var nameA: String?
    @State private var nameB: String?
    @State private var comparison: ProfileComparison?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let err = loadError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                }
                if let cmp = comparison {
                    identityCard(cmp)
                    metricsCard(cmp)
                    consumersCard(cmp)
                    assertionsCard(cmp)
                    servicesCard(cmp)
                    aiCard(cmp)
                } else {
                    emptyState
                }
            }
            .padding()
        }
    }

    // MARK: - Header / pickers

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare Two Macs").font(.title3).bold()
            Text("Export a Device Profile on each Mac (Export tab), then load both here to see exactly what differs.")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 12) {
                pickButton(label: "A", file: nameA) { pick(into: .a) }
                Image(systemName: "arrow.left.arrow.right")
                pickButton(label: "B", file: nameB) { pick(into: .b) }
            }
        }
    }

    private func pickButton(label: String, file: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile \(label)").font(.caption).foregroundColor(.secondary)
                Text(file ?? "Choose JSON…").font(.callout).fontWeight(.medium).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.split.2x1").font(.system(size: 32)).foregroundColor(.secondary)
            Text("Load profile A and B to compare").foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // MARK: - Cards

    private func identityCard(_ c: ProfileComparison) -> some View {
        CardView(title: "Devices") {
            HStack(alignment: .top, spacing: 16) {
                deviceColumn(c.labelA, profileA)
                Divider()
                deviceColumn(c.labelB, profileB)
            }
        }
    }

    private func deviceColumn(_ label: String, _ p: DeviceProfile?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).fontWeight(.semibold).lineLimit(1)
            if let p {
                Text(p.device.chip).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text(p.device.macOSVersion).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                Text("\(p.dataWindowDays)-day window").font(.caption2).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricsCard(_ c: ProfileComparison) -> some View {
        CardView(title: "Power & Health") {
            VStack(spacing: 6) {
                HStack {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    Text(c.labelA).font(.caption2).foregroundColor(.secondary).frame(width: 90, alignment: .trailing).lineLimit(1)
                    Text(c.labelB).font(.caption2).foregroundColor(.secondary).frame(width: 90, alignment: .trailing).lineLimit(1)
                }
                ForEach(c.metrics) { m in
                    HStack {
                        Text(m.label).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        Text(fmt(m.valueA, m.unit))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(m.worseSide == .a ? .red : .primary)
                            .frame(width: 90, alignment: .trailing)
                        Text(fmt(m.valueB, m.unit))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(m.worseSide == .b ? .red : .primary)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func consumersCard(_ c: ProfileComparison) -> some View {
        CardView(title: "Per-App Energy (matched by name)") {
            if c.consumers.isEmpty {
                Text("No process data in either profile.").font(.caption).foregroundColor(.secondary)
            } else {
                VStack(spacing: 5) {
                    ForEach(c.consumers.prefix(20)) { d in
                        HStack {
                            Text(d.name).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(d.presentA ? String(format: "%.0f", d.energyA) : "—")
                                .font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                                .foregroundColor(d.presentA ? .primary : .secondary)
                            Text(d.presentB ? String(format: "%.0f", d.energyB) : "—")
                                .font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                                .foregroundColor(d.presentB ? .primary : .secondary)
                            Text(ratioLabel(d)).font(.caption2.monospacedDigit())
                                .foregroundColor(ratioColor(d)).frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func assertionsCard(_ c: ProfileComparison) -> some View {
        CardView(title: "Sleep Preventers") {
            VStack(alignment: .leading, spacing: 6) {
                assertionRow("Only on \(c.labelA)", c.assertionsOnlyA, .orange)
                assertionRow("Only on \(c.labelB)", c.assertionsOnlyB, .orange)
                assertionRow("Both", c.assertionsBoth, .secondary)
                if c.assertionsOnlyA.isEmpty && c.assertionsOnlyB.isEmpty && c.assertionsBoth.isEmpty {
                    Text("No sleep-preventing assertions recorded in either profile.").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func assertionRow(_ title: String, _ items: [String], _ color: Color) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption2).foregroundColor(.secondary)
                    Text(items.joined(separator: ", ")).font(.caption).foregroundColor(color)
                }
            }
        }
    }

    private func servicesCard(_ c: ProfileComparison) -> some View {
        CardView(title: "Background Services") {
            VStack(alignment: .leading, spacing: 6) {
                assertionRow("Only on \(c.labelA)", c.servicesOnlyA, .orange)
                assertionRow("Only on \(c.labelB)", c.servicesOnlyB, .orange)
                if c.servicesOnlyA.isEmpty && c.servicesOnlyB.isEmpty {
                    Text("Same third-party background services on both (or none recorded).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func aiCard(_ c: ProfileComparison) -> some View {
        CardView(title: "AI Comparison") {
            VStack(alignment: .leading, spacing: 10) {
                if narrative.isGeneratingComparison {
                    HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Analyzing the difference…").font(.callout).foregroundColor(.secondary) }
                } else if let result = narrative.comparison {
                    Text(result.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack { AIProviderBadge(result: result); Spacer()
                        Button("Regenerate") { Task { await narrative.generateComparison(c) } }
                            .buttonStyle(.borderless).font(.caption).foregroundColor(.accentColor) }
                } else if let err = narrative.comparisonError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                    Button("Retry") { Task { await narrative.generateComparison(c) } }.buttonStyle(.borderless).font(.caption)
                } else if narrative.anyAIAvailable {
                    Button("Explain the difference (AI)") { Task { await narrative.generateComparison(c) } }.buttonStyle(.bordered)
                } else {
                    Text("Enable Apple Intelligence or Ollama in Settings for an AI comparison.").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private enum Slot { case a, b }

    private func pick(into slot: Slot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.directoryURL = ReportExporter.exportsDirectory
        panel.message = "Choose a PowerSleuth device profile (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let profile = try decoder.decode(DeviceProfile.self, from: data)
            loadError = nil
            switch slot {
            case .a: profileA = profile; nameA = url.lastPathComponent
            case .b: profileB = profile; nameB = url.lastPathComponent
            }
            rebuild()
        } catch {
            loadError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func rebuild() {
        guard let a = profileA, let b = profileB else { comparison = nil; return }
        comparison = ProfileComparison.compare(a, b)
        narrative.comparison = nil   // reset stale AI narrative for the new pair
    }

    private func fmt(_ v: Double, _ unit: String) -> String {
        unit.isEmpty ? String(format: "%.0f", v) : String(format: "%.1f %@", v, unit)
    }

    private func ratioLabel(_ d: ProfileComparison.ConsumerDelta) -> String {
        if let r = d.ratio { return String(format: "%.1f×", r) }
        if d.presentA && !d.presentB { return "A only" }
        if d.presentB && !d.presentA { return "B only" }
        return ""
    }

    private func ratioColor(_ d: ProfileComparison.ConsumerDelta) -> Color {
        guard let r = d.ratio else { return .secondary }
        return (r >= 1.5 || r <= 0.67) ? .orange : .secondary
    }
}
