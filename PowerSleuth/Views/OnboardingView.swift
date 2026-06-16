import SwiftUI

struct OnboardingView: View {
    @Binding var showOnboarding: Bool
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                whatWeMonitorPage.tag(1)
                howLongPage.tag(2)
                howToUsePage.tag(3)
                setupPage.tag(4)
                aiSetupPage.tag(5)
            }
            .tabViewStyle(.automatic)
            .frame(width: 560, height: 420)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                        .buttonStyle(.borderless)
                }
                Spacer()
                pageIndicator
                Spacer()
                if page < 5 {
                    Button("Next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Monitoring") {
                        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
                        showOnboarding = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 560)
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)
            Text("Welcome to PowerSleuth")
                .font(.largeTitle).bold()
            Text("A deep-dive battery analyst for your Mac.\nIt studies your system over time and tells you **exactly** what's draining your battery — not just the percentage.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 400)
        }
        .padding(40)
    }

    private var whatWeMonitorPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What We Monitor")
                .font(.title2).bold()
                .padding(.bottom, 4)

            MonitorRow(icon: "bolt.fill",         color: .yellow,  title: "Real Power Draw",      desc: "Actual Watts from the battery controller — not an estimate")
            MonitorRow(icon: "cpu.fill",           color: .blue,    title: "Per-Process Energy",   desc: "Same \"Energy Impact\" score Activity Monitor uses, every 60s")
            MonitorRow(icon: "memorychip.fill",    color: .purple,  title: "CPU & RAM",            desc: "System-wide CPU load, memory pressure, and swap activity")
            MonitorRow(icon: "network",            color: .green,   title: "Network I/O",          desc: "Per-app bytes in/out — data hogs burn battery on cellular too")
            MonitorRow(icon: "moon.fill",          color: .indigo,  title: "Sleep Drain",          desc: "Tracks drain while the lid is closed + what kept it awake")
            MonitorRow(icon: "heart.fill",         color: .red,     title: "Battery Health",       desc: "Cycle count, capacity retention, and long-term health trend")
        }
        .padding(32)
    }

    private var howLongPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("How Long Should It Run?")
                .font(.title2).bold()

            TimelineRow(time: "15 min", icon: "clock",          color: .blue,   title: "Active consumers identified",      desc: "Sees which apps are burning energy right now")
            TimelineRow(time: "1 hour",  icon: "clock.fill",    color: .blue,   title: "Drain rate baseline",              desc: "Reliable watts-per-hour for current workload")
            TimelineRow(time: "24 hrs",  icon: "moon.stars",    color: .indigo, title: "Sleep drain data",                 desc: "Captures overnight drain + sleep wake patterns ← minimum")
            TimelineRow(time: "7 days",  icon: "calendar",      color: .green,  title: "Strong comparison baseline",       desc: "Covers your full weekly usage pattern ← recommended")
            TimelineRow(time: "2 weeks", icon: "checkmark.seal",color: .orange, title: "Ideal for cross-Mac comparison",   desc: "Enough data to confidently compare two machines")

            Text("Tip: Install on both Macs you want to compare. Let each run for 7+ days, then use Export → Device Profile to compare them side by side.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(32)
    }

    private var howToUsePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Getting the Most Out of It")
                .font(.title2).bold()

            TipRow(num: "1", title: "Use your Mac normally",       desc: "The more variety in your sessions, the better the baseline. Don't change behavior for the tool.")
            TipRow(num: "2", title: "Check the Analysis tab daily", desc: "It updates every 60s. Look for patterns — does drain spike at certain times?")
            TipRow(num: "3", title: "Compare Macs via Export",     desc: "Export → Device Profile from each Mac. Compare top consumers, sleep drain rate, and avg Watts.")
            TipRow(num: "4", title: "Watch the sleep drain rate",  desc: ">2%/hr overnight = something is keeping your Mac awake. Check \"Preventing Sleep\" in the popover.")
            TipRow(num: "5", title: "Filter by time window",       desc: "History charts let you isolate specific days — great for \"why was battery so bad Tuesday?\"")
        }
        .padding(32)
    }

    private var setupPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Ready to Go")
                .font(.title2).bold()

            VStack(alignment: .leading, spacing: 12) {
                CheckRow(text: "No special permissions required")
                CheckRow(text: "No root access or system extensions")
                CheckRow(text: "Data stays on your Mac — no cloud sync")
                CheckRow(text: "~30 MB RAM, samples every 30–60 seconds")
            }
            .padding(.vertical, 8)

            VStack(spacing: 8) {
                Text("Add to Login Items for continuous monitoring")
                    .font(.callout).foregroundColor(.secondary)
                Button("Open Login Items Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(40)
    }

    private var aiSetupPage: some View {
        AISetupOnboardingPage()
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<6) { i in
                Circle()
                    .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Helper rows

private struct MonitorRow: View {
    let icon: String; let color: Color; let title: String; let desc: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct TimelineRow: View {
    let time: String; let icon: String; let color: Color; let title: String; let desc: String
    var body: some View {
        HStack(spacing: 12) {
            Text(time).font(.caption).monospacedDigit().foregroundColor(.secondary).frame(width: 48, alignment: .trailing)
            Image(systemName: icon).foregroundColor(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct TipRow: View {
    let num: String; let title: String; let desc: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num).font(.headline).foregroundColor(.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct CheckRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").foregroundColor(.green).font(.caption)
            Text(text).font(.callout)
        }
    }
}

// MARK: - AI Setup page (uses OllamaService singleton)

private struct AISetupOnboardingPage: View {
    @ObservedObject private var ollama    = OllamaService.shared
    @ObservedObject private var narrative = NarrativeEngine.shared
    @AppStorage("ai.ollamaModel")         private var ollamaModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "brain").font(.system(size: 36)).foregroundStyle(.purple.gradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Analysis (Optional)")
                        .font(.title2).bold()
                    Text("Adds natural language summaries and deeper findings to the Analysis tab.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Apple Intelligence status
            HStack(spacing: 10) {
                Image(systemName: narrative.appleIntelligenceAvailable ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundColor(narrative.appleIntelligenceAvailable ? .green : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence").font(.callout).fontWeight(.medium)
                    Text(narrative.appleIntelligenceAvailable
                         ? "Available — on-device, private, no setup needed."
                         : "Not available on this Mac / macOS version.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Divider()

            // Ollama section
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: ollama.isDetected ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundColor(ollama.isDetected ? .green : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ollama (Local LLM)").font(.callout).fontWeight(.medium)
                        Text("Best for AI Findings. Runs locally — private and free.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if !ollama.isDetected {
                        Link("Install →", destination: URL(string: "https://ollama.ai")!)
                            .font(.caption).buttonStyle(.bordered)
                    }
                    Button(ollama.isChecking ? "Checking…" : "Detect") {
                        Task { await ollama.check() }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(ollama.isChecking)
                }

                if ollama.isDetected, !ollama.models.isEmpty {
                    Picker("Select model", selection: $ollamaModel) {
                        Text("— select —").tag("")
                        ForEach(ollama.models) { m in
                            Text("\(m.name)  ·  \(m.sizeLabel)").tag(m.name)
                        }
                    }
                    Text("Recommended: llama3.2:latest, qwen2.5:7b, or mistral:7b (7B+ for best reasoning)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            Text("You can change these anytime in Settings → AI Analysis.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(32)
        .task { await ollama.check() }
    }
}
