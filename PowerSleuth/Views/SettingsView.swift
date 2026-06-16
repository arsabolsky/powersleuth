import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsPane()
                .tabItem { Label("AI Analysis", systemImage: "brain") }
            MonitoringSettingsPane()
                .tabItem { Label("Monitoring", systemImage: "chart.xyaxis.line") }
        }
        .frame(width: 540, height: 500)
    }
}

// MARK: - AI Settings

private struct AISettingsPane: View {
    @ObservedObject private var ollama    = OllamaService.shared
    @ObservedObject private var narrative = NarrativeEngine.shared

    @AppStorage("ai.useAppleIntelligence") private var useAppleIntelligence = true
    @AppStorage("ai.useOllama")            private var useOllama = true
    @AppStorage("ai.ollamaModel")          private var ollamaModel = ""
    @AppStorage("ai.enableSummary")        private var enableSummary = true
    @AppStorage("ai.enableFindings")       private var enableFindings = true

    var body: some View {
        Form {
            // Apple Intelligence
            Section {
                HStack {
                    Label("Status", systemImage: "apple.logo")
                    Spacer()
                    if narrative.appleIntelligenceAvailable {
                        Label("Available", systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                    } else {
                        Label("Not available", systemImage: "xmark.circle").foregroundColor(.secondary).font(.caption)
                    }
                }
                if narrative.appleIntelligenceAvailable {
                    Toggle("Use for AI Summary (preferred)", isOn: $useAppleIntelligence)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text(narrative.appleIntelligenceAvailable
                    ? "On-device, private. Best for AI Summary — runs instantly without network."
                    : "Requires macOS 26 (Tahoe) on an eligible Mac with Apple Intelligence enabled."
                )
                .font(.caption).foregroundColor(.secondary)
            }

            // Ollama
            Section {
                HStack {
                    Label("Status", systemImage: "server.rack")
                    Spacer()
                    if ollama.isDetected {
                        Label("\(ollama.models.count) model\(ollama.models.count == 1 ? "" : "s") detected",
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green).font(.caption)
                    } else {
                        Label("Not running", systemImage: "xmark.circle").foregroundColor(.secondary).font(.caption)
                    }
                    Button(ollama.isChecking ? "Checking…" : "Detect") {
                        Task { await ollama.check() }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(ollama.isChecking)
                }

                if ollama.isDetected {
                    Toggle("Use for AI Analysis", isOn: $useOllama)

                    Picker("Model", selection: $ollamaModel) {
                        Text("— select a model —").tag("")
                        ForEach(ollama.models) { m in
                            HStack {
                                Text(m.name)
                                Spacer()
                                Text(m.sizeLabel).foregroundColor(.secondary)
                            }
                            .tag(m.name)
                        }
                    }
                    .disabled(!useOllama)

                    if !ollamaModel.isEmpty {
                        Text("Tip: 7B+ models give the best reasoning (llama3.2:7b, qwen2.5:7b, mistral:7b)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("Ollama not found at localhost:11434.").font(.caption).foregroundColor(.secondary)
                        Link("Install Ollama →", destination: URL(string: "https://ollama.ai")!)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Ollama (Local LLM)")
            } footer: {
                Text("Best for AI Findings — larger models can reason across correlated metrics. Privacy: all inference stays on your Mac.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Feature toggles
            Section("Features") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("AI Summary", isOn: $enableSummary)
                    Text("2-3 sentence plain-English explanation of the primary drain cause")
                        .font(.caption).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("AI Findings", isOn: $enableFindings)
                    Text("Deep correlation analysis. Ollama recommended; Apple Intelligence as fallback.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await ollama.check() }
    }
}

// MARK: - Monitoring Settings

private struct MonitoringSettingsPane: View {
    @AppStorage("monitoring.sampleInterval")         private var sampleInterval = 30
    @AppStorage("monitoring.retentionDays")          private var retentionDays = 30
    @AppStorage("monitoring.highDrainAlertEnabled")  private var alertEnabled = false
    @AppStorage("monitoring.highDrainAlertWatts")    private var alertWatts = 20.0
    @AppStorage("deepPower.enabled")                 private var deepPowerEnabled = false

    @ObservedObject private var deep = DeepPowerSampler.shared
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Data Collection") {
                Picker("Battery sample interval", selection: $sampleInterval) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Data retention", selection: $retentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Battery/system sampling interval applies after the next launch. Longer retention improves trend analysis; each day uses ~2–5 MB.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Alerts") {
                Toggle("High drain alert", isOn: $alertEnabled)
                    .onChange(of: alertEnabled) { _, on in
                        if on { DrainNotifier.requestAuthorization() }
                    }
                if alertEnabled {
                    HStack {
                        Text("Threshold")
                        Spacer()
                        Stepper("\(Int(alertWatts)) W", value: $alertWatts, in: 5...50, step: 1)
                    }
                    Text("Notifies when sustained drain exceeds this for more than 5 minutes.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Deep Power Mode", isOn: $deepPowerEnabled)
                    .disabled(!deep.available)
                    .onChange(of: deepPowerEnabled) { _, on in
                        if on {
                            Task {
                                let ok = await deep.start()
                                if !ok { deepPowerEnabled = false }
                            }
                        } else {
                            deep.stop()
                        }
                    }
                HStack {
                    Text("Status").foregroundColor(.secondary)
                    Spacer()
                    if !deep.available {
                        Text("powermetrics unavailable").font(.caption).foregroundColor(.secondary)
                    } else if deep.isRunning {
                        Label("Running", systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                    } else if let e = deep.lastError {
                        Text(e).font(.caption).foregroundColor(.orange).lineLimit(2)
                    } else {
                        Text("Off").font(.caption).foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Deep Power Mode (requires admin)")
            } footer: {
                Text("Installs a background helper (one admin prompt, once) that runs Apple's powermetrics to measure true CPU/GPU/ANE wattage plus per-process CPU and energy. Apple Silicon doesn't expose per-app GPU, so GPU watts are system-wide. Off by default; all other monitoring works without it.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItem.setEnabled(on) { launchAtLogin = LoginItem.isEnabled }
                    }
                Text("Registers PowerSleuth to start at login so monitoring runs continuously across reboots.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
