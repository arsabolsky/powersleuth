import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Understanding PowerSleuth")
                    .font(.title3).bold()

                HelpSection(title: "How Long Should I Run It?") {
                    VStack(alignment: .leading, spacing: 6) {
                        HelpTimeRow(time: "15 min", detail: "Active top consumers identified")
                        HelpTimeRow(time: "1 hour",  detail: "Reliable active drain rate baseline")
                        HelpTimeRow(time: "24 hours", detail: "Sleep drain data captured — minimum for meaningful insights")
                        HelpTimeRow(time: "7 days",  detail: "Strong comparison baseline (recommended)")
                        HelpTimeRow(time: "2 weeks", detail: "Ideal for comparing two different Macs")
                    }
                }

                HelpSection(title: "Understanding the Metrics") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpTerm(term: "System Power (W)", def: "Actual watts measured by the battery controller — the ground truth of how hard your Mac is working")
                        HelpTerm(term: "Energy Impact", def: "The same score Activity Monitor shows in the Energy column. It combines CPU time, wakeups, GPU, and network — higher = more drain")
                        HelpTerm(term: "Sleep Drain (%/hr)", def: "How much battery % you lose per hour when the lid is closed. Normal is <2%/hr; >3%/hr means something is keeping your Mac awake")
                        HelpTerm(term: "Power Assertion", def: "A lock a process holds to prevent your Mac from entering deep sleep. The most common cause of excessive sleep drain")
                        HelpTerm(term: "Thermal State", def: "Serious or Critical means your Mac is running hot, which forces higher clock speeds and more power draw")
                        HelpTerm(term: "Capacity Retention", def: "Your battery's current maximum charge vs. its original design. Below 80% means you effectively have a smaller battery")
                    }
                }

                HelpSection(title: "Comparing Two Macs") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Install PowerSleuth on both Macs and let each run for 7+ days. Then:")
                            .font(.callout)
                        HelpStep(num: 1, text: "Go to Export → Device Profile on each Mac")
                        HelpStep(num: 2, text: "Transfer the JSON files to one machine")
                        HelpStep(num: 3, text: "Compare these fields:")
                        Text("""
                             • avgActiveWatts — idle power draw (lower = better)
                             • avgSleepDrainPctPerHour — overnight drain
                             • topConsumers — which apps differ between machines
                             • powerAssertionHolders — what prevents sleep
                             • battery.retentionPct — health difference
                             """)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(6)
                        Text("If one Mac has significantly higher avgActiveWatts, its topConsumers list will tell you why.")
                            .font(.callout).foregroundColor(.secondary)
                    }
                }

                HelpSection(title: "Common Issues & Fixes") {
                    VStack(alignment: .leading, spacing: 8) {
                        HelpFix(issue: "High sleep drain (>3%/hr)",
                                fix: "Check \"Preventing Sleep\" in the popover. Common culprits: coreaudiod (audio device connected?), cloudd (iCloud sync), mDNSResponder (network service). Try disconnecting peripherals.")
                        HelpFix(issue: "Consistently high Watts (>15W idle)",
                                fix: "Look at Top Consumers for sustained high Energy Impact. Browser helper processes (Chrome, Edge) and background ML/AI processes are common culprits.")
                        HelpFix(issue: "Thermal State: Serious/Critical",
                                fix: "High temperature forces higher power draw. Ensure cooling vents aren't blocked. Check Activity Monitor for processes pinning CPU at 100%.")
                        HelpFix(issue: "Battery health <80%",
                                fix: "Your battery has degraded. This is the primary reason a few-months-old Mac might have worse range than a newer one. Apple Stores can replace the battery.")
                        HelpFix(issue: "Energy Impact not showing",
                                fix: "PowerSleuth uses `top` to collect this data. It samples every 60 seconds — wait 1–2 minutes after launch for data to appear.")
                    }
                }

                HelpSection(title: "Data & Privacy") {
                    Text("All data is stored locally at ~/Library/Application Support/PowerSleuth/powersleuth.db. Nothing leaves your Mac. No analytics, no telemetry. The database is pruned to 30 days automatically.")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
            .padding()
        }
    }
}

// MARK: - Sub-views

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }
}

private struct HelpTimeRow: View {
    let time: String; let detail: String
    var body: some View {
        HStack {
            Text(time).font(.callout.monospacedDigit()).foregroundColor(.accentColor).frame(width: 70, alignment: .leading)
            Text(detail).font(.callout).foregroundColor(.secondary)
        }
    }
}

private struct HelpTerm: View {
    let term: String; let def: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(.callout).fontWeight(.semibold)
            Text(def).font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct HelpStep: View {
    let num: Int; let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(num).").foregroundColor(.accentColor).font(.callout).frame(width: 18)
            Text(text).font(.callout)
        }
    }
}

private struct HelpFix: View {
    let issue: String; let fix: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.callout.bold())
            Text(fix).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
