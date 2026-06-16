import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIProvider: String, Sendable {
    case appleIntelligence = "Apple Intelligence"
    case ollama = "Ollama"
}

struct AIResult: Sendable {
    let text: String
    let provider: AIProvider
    let modelName: String?
}

@MainActor
final class NarrativeEngine: ObservableObject {
    static let shared = NarrativeEngine()
    private init() {}

    @Published var summary: AIResult?
    @Published var findings: AIResult?
    @Published var comparison: AIResult?
    @Published var isGeneratingSummary = false
    @Published var isGeneratingFindings = false
    @Published var isGeneratingComparison = false
    @Published var summaryError: String?
    @Published var findingsError: String?
    @Published var comparisonError: String?

    var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    var ollamaReady: Bool {
        OllamaService.shared.isDetected &&
        !(UserDefaults.standard.string(forKey: "ai.ollamaModel") ?? "").isEmpty
    }

    var anyAIAvailable: Bool { appleIntelligenceAvailable || ollamaReady }

    // Fetches all needed data and runs both generations concurrently
    func generateAll() async {
        let diagnosis = AnalysisEngine.shared.analyze()
        let metrics   = try? DatabaseService.shared.fetchLatestSystemMetrics()
        let since     = Date().addingTimeInterval(-3600)
        let processes = (try? DatabaseService.shared.fetchProcessAggregations(since: since, limit: 10)) ?? []

        async let s: () = generateSummary(diagnosis: diagnosis, metrics: metrics)
        async let f: () = generateFindings(diagnosis: diagnosis, metrics: metrics, processes: processes)
        _ = await (s, f)
    }

    // MARK: - Summary  (Apple Intelligence preferred — short, fits small model well)

    func generateSummary(diagnosis: DrainDiagnosis, metrics: SystemMetrics?) async {
        guard UserDefaults.standard.bool(forKey: "ai.enableSummary") else { return }
        isGeneratingSummary = true
        summaryError = nil
        defer { isGeneratingSummary = false }

        let prompt = summaryPrompt(diagnosis: diagnosis, metrics: metrics)
        let sysCtx = "You are a concise macOS battery expert. Write exactly 2-3 sentences."

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           UserDefaults.standard.bool(forKey: "ai.useAppleIntelligence"),
           appleIntelligenceAvailable {
            if let text = try? await appleGenerate(prompt: prompt, instructions: sysCtx) {
                summary = AIResult(text: text, provider: .appleIntelligence, modelName: nil)
                return
            }
        }
        #endif

        let model = UserDefaults.standard.string(forKey: "ai.ollamaModel") ?? ""
        if UserDefaults.standard.bool(forKey: "ai.useOllama"),
           OllamaService.shared.isDetected, !model.isEmpty {
            do {
                let text = try await OllamaService.shared.generate(
                    model: model, prompt: sysCtx + "\n\n" + prompt
                )
                summary = AIResult(text: text, provider: .ollama, modelName: model)
            } catch {
                summaryError = error.localizedDescription
            }
        }
    }

    // MARK: - Findings  (Ollama preferred — better multi-step reasoning)

    func generateFindings(diagnosis: DrainDiagnosis, metrics: SystemMetrics?, processes: [ProcessAggregation]) async {
        guard UserDefaults.standard.bool(forKey: "ai.enableFindings") else { return }
        isGeneratingFindings = true
        findingsError = nil
        defer { isGeneratingFindings = false }

        let prompt = findingsPrompt(diagnosis: diagnosis, metrics: metrics, processes: processes)
        let sysCtx = "You are a macOS battery analysis expert. Identify correlations and give specific, data-driven recommendations."

        let model = UserDefaults.standard.string(forKey: "ai.ollamaModel") ?? ""
        if UserDefaults.standard.bool(forKey: "ai.useOllama"),
           OllamaService.shared.isDetected, !model.isEmpty {
            do {
                let text = try await OllamaService.shared.generate(
                    model: model, prompt: sysCtx + "\n\n" + prompt
                )
                findings = AIResult(text: text, provider: .ollama, modelName: model)
                return
            } catch {
                findingsError = error.localizedDescription
            }
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           UserDefaults.standard.bool(forKey: "ai.useAppleIntelligence"),
           appleIntelligenceAvailable {
            do {
                let text = try await appleGenerate(prompt: prompt, instructions: sysCtx)
                findings = AIResult(text: text, provider: .appleIntelligence, modelName: nil)
            } catch {
                findingsError = error.localizedDescription
            }
        }
        #endif
    }

    // MARK: - Comparison  (cross-Mac diff narrative; Ollama preferred)

    func generateComparison(_ comp: ProfileComparison) async {
        isGeneratingComparison = true
        comparisonError = nil
        defer { isGeneratingComparison = false }

        let prompt = comparisonPrompt(comp)
        let sysCtx = "You are a macOS battery expert comparing two Macs. Explain concretely why one drains faster, citing the specific metrics and apps that differ. End with the single highest-impact fix."

        let model = UserDefaults.standard.string(forKey: "ai.ollamaModel") ?? ""
        if UserDefaults.standard.bool(forKey: "ai.useOllama"),
           OllamaService.shared.isDetected, !model.isEmpty {
            do {
                let text = try await OllamaService.shared.generate(model: model, prompt: sysCtx + "\n\n" + prompt)
                comparison = AIResult(text: text, provider: .ollama, modelName: model)
                return
            } catch {
                comparisonError = error.localizedDescription
            }
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           UserDefaults.standard.bool(forKey: "ai.useAppleIntelligence"),
           appleIntelligenceAvailable {
            do {
                let text = try await appleGenerate(prompt: prompt, instructions: sysCtx)
                comparison = AIResult(text: text, provider: .appleIntelligence, modelName: nil)
            } catch {
                comparisonError = error.localizedDescription
            }
        }
        #endif
    }

    // MARK: - Apple Intelligence

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func appleGenerate(prompt: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }
    #endif

    // MARK: - Prompt builders

    private func summaryPrompt(diagnosis: DrainDiagnosis, metrics: SystemMetrics?) -> String {
        ([
            "Write 2-3 sentences explaining why this Mac's battery is draining and one specific fix:\n"
        ] + contextLines(diagnosis: diagnosis, metrics: metrics, processes: [])).joined(separator: "\n")
    }

    private func findingsPrompt(diagnosis: DrainDiagnosis, metrics: SystemMetrics?, processes: [ProcessAggregation]) -> String {
        ([
            "Analyze this Mac battery data and provide:",
            "1. Root causes and correlations (e.g. Chrome heating CPU which draws extra cooling watts)",
            "2. Whether each metric is normal or abnormal with context",
            "3. Two or three actionable steps ordered by expected impact",
            "Cite specific numbers. Avoid generic advice.\n"
        ] + contextLines(diagnosis: diagnosis, metrics: metrics, processes: processes)).joined(separator: "\n")
    }

    private func comparisonPrompt(_ c: ProfileComparison) -> String {
        var lines: [String] = [
            "Compare two Macs (A=\(c.labelA), B=\(c.labelB)) and explain why one drains faster.",
            "Metrics (A vs B):"
        ]
        for m in c.metrics {
            lines.append("  \(m.label): \(String(format: "%.1f", m.valueA))\(m.unit) vs \(String(format: "%.1f", m.valueB))\(m.unit)")
        }
        let notable = c.consumers.prefix(12).map { d -> String in
            let a = d.presentA ? String(format: "%.0f", d.energyA) : "absent"
            let b = d.presentB ? String(format: "%.0f", d.energyB) : "absent"
            return "  \(d.name): A=\(a) B=\(b)"
        }
        if !notable.isEmpty { lines.append("Per-app energy impact (A vs B):"); lines.append(contentsOf: notable) }
        if !c.assertionsOnlyA.isEmpty { lines.append("Sleep-preventers only on A: \(c.assertionsOnlyA.joined(separator: ", "))") }
        if !c.assertionsOnlyB.isEmpty { lines.append("Sleep-preventers only on B: \(c.assertionsOnlyB.joined(separator: ", "))") }
        lines.append("\nWrite 3-5 sentences: which Mac is worse and the concrete reasons (name the apps/metrics), then the top fix.")
        return lines.joined(separator: "\n")
    }

    private func contextLines(diagnosis: DrainDiagnosis, metrics: SystemMetrics?, processes: [ProcessAggregation]) -> [String] {
        var lines: [String] = []
        lines.append("Current drain: \(String(format: "%.1f", diagnosis.currentWatts))W (\(diagnosis.level.label))")

        if let h = diagnosis.capacityRetentionPct {
            lines.append("Battery health: \(Int(h))% — \(diagnosis.cycleCount ?? 0) cycles")
        }
        if !diagnosis.culprits.isEmpty {
            lines.append("Rule findings: \(diagnosis.culprits.joined(separator: "; "))")
        }
        if !processes.isEmpty {
            lines.append("Top processes:")
            for p in processes.prefix(8) {
                lines.append("  \(p.name): energy=\(Int(p.avgEnergyImpact)) cpu=\(String(format: "%.1f", p.avgCpuPct))% mem=\(Int(p.avgMemMb))MB [\(p.impactLevel)]")
            }
        }
        if let m = metrics {
            lines.append("CPU: \(Int(m.cpuUsedPct))% (user \(Int(m.cpuUserPct))% sys \(Int(m.cpuSysPct))%)")
            lines.append("RAM pressure: \(Int(m.ramPressurePct))% | load: \(String(format: "%.2f", m.loadAvg1m))")
            if m.diskReadMbS > 0.5 || m.diskWriteMbS > 0.5 {
                lines.append("Disk: read \(String(format: "%.1f", m.diskReadMbS)) MB/s  write \(String(format: "%.1f", m.diskWriteMbS)) MB/s")
            }
            if m.systemWatts > 0 {
                lines.append("Measured watts: \(String(format: "%.1f", m.systemWatts))W")
            }
            if m.gpuUtilPct > 0 {
                lines.append("GPU utilization: \(Int(m.gpuUtilPct))% | VRAM in use: \(Int(m.vramInUseMb))MB")
            }
        }
        if !diagnosis.topAssertors.isEmpty {
            let list = diagnosis.topAssertors.map { "\($0.processName) (\($0.assertionType))" }.joined(separator: ", ")
            lines.append("Sleep prevented by: \(list)")
        }
        return lines
    }
}
