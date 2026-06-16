import SwiftUI

struct ExportView: View {
    @State private var isGenerating = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var profilePreview: String?
    @State private var windowDays = 7
    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                exportOptionsSection
                dataInfoSection
                if let preview = profilePreview {
                    previewSection(preview)
                }
            }
            .padding()
        }
        .frame(minHeight: 400)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export & Compare")
                .font(.title3).bold()
            Text("Export a Device Profile to compare this Mac against another. Install PowerSleuth on both Macs, let both collect data for 7+ days, then compare the exported profiles.")
                .font(.callout).foregroundColor(.secondary)
        }
    }

    private var exportOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Options").font(.headline)

            HStack {
                Text("Data window").font(.callout)
                Picker("Days", selection: $windowDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            HStack(spacing: 12) {
                ExportButton(title: "Device Profile",
                             subtitle: "JSON for comparison",
                             icon: "doc.badge.arrow.up",
                             color: .blue) {
                    exportProfile()
                }
                ExportButton(title: "Summary Report",
                             subtitle: "Markdown document",
                             icon: "doc.richtext",
                             color: .green) {
                    exportMarkdown()
                }
                ExportButton(title: "Raw Data",
                             subtitle: "CSV for spreadsheets",
                             icon: "tablecells",
                             color: .orange) {
                    exportCSV()
                }
            }

            if isGenerating {
                ProgressView("Generating…").padding(.top, 4)
            }
            if let url = exportedURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Saved to Desktop: \(url.lastPathComponent)")
                        .font(.callout)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(10)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
            if let err = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text(err).font(.callout).foregroundColor(.orange)
                }
            }
        }
    }

    private var dataInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to Compare Two Macs").font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                CompareStep(num: 1, text: "Install PowerSleuth on both Macs")
                CompareStep(num: 2, text: "Let both run for at least 7 days (same usage pattern if possible)")
                CompareStep(num: 3, text: "Export \"Device Profile\" (JSON) from each Mac")
                CompareStep(num: 4, text: "Compare: avgActiveWatts, sleepDrainPctPerHour, topConsumers")
                CompareStep(num: 5, text: "The Mac with higher values in those fields is the one draining faster — now you know why")
            }

            Divider()

            Text("Key fields to compare in the JSON:")
                .font(.caption).foregroundColor(.secondary)
            Text("""
                averageMetrics.avgActiveWatts     → idle power draw
                averageMetrics.avgSleepDrainPctPerHour → overnight drain
                topConsumers[0..2]                 → biggest energy hogs
                powerAssertionHolders              → what prevents deep sleep
                battery.retentionPct               → health difference
                """)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(6)
        }
    }

    private func previewSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .background(Color(.textBackgroundColor))
            .cornerRadius(6)
        }
    }

    // MARK: - Actions

    private func exportProfile() {
        isGenerating = true; exportedURL = nil; errorMessage = nil
        Task {
            do {
                let profile = try await ReportExporter.shared.buildDeviceProfile(windowDays: windowDays)
                let url = try ReportExporter.shared.exportJSON(profile)
                let preview = String(data: (try? profile.toJSON()) ?? Data(), encoding: .utf8) ?? ""
                await MainActor.run {
                    exportedURL = url
                    profilePreview = String(preview.prefix(2000))
                    isGenerating = false
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; isGenerating = false }
            }
        }
    }

    private func exportMarkdown() {
        isGenerating = true; exportedURL = nil; errorMessage = nil
        Task {
            do {
                let profile = try await ReportExporter.shared.buildDeviceProfile(windowDays: windowDays)
                let url = try ReportExporter.shared.exportMarkdown(profile)
                await MainActor.run { exportedURL = url; isGenerating = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; isGenerating = false }
            }
        }
    }

    private func exportCSV() {
        isGenerating = true; exportedURL = nil; errorMessage = nil
        Task {
            do {
                let url = try ReportExporter.shared.exportCSV(windowDays: windowDays)
                await MainActor.run { exportedURL = url; isGenerating = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; isGenerating = false }
            }
        }
    }
}

// MARK: - Sub-views

private struct ExportButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundColor(color)
                Text(title).font(.callout).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
        .buttonStyle(.bordered)
    }
}

private struct CompareStep: View {
    let num: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num).").font(.callout).foregroundColor(.accentColor).frame(width: 18)
            Text(text).font(.callout)
        }
    }
}
