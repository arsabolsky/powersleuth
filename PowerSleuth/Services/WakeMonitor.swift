import Foundation

/// Parses `pmset -g log` for wake/dark-wake events — what wakes the Mac (and how often)
/// during sleep. Dark wakes for Maintenance / background refresh / network are the usual
/// overnight-drain culprits. Runs every 30 min on a background queue.
@MainActor
final class WakeMonitor: ObservableObject {
    @Published var summary: WakeSummary?

    private var timer: Timer?

    init() { start() }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        Task { await sample() }
    }

    func sample() async {
        let events = await Self.collect()
        if !events.isEmpty { try? DatabaseService.shared.saveWakeEvents(events) }
        summary = try? DatabaseService.shared.fetchWakeSummary(since: Date().addingTimeInterval(-86400))
    }

    private nonisolated static func collect() async -> [WakeEvent] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let output = shell("/usr/bin/pmset", ["-g", "log"])
                cont.resume(returning: parse(output))
            }
        }
    }

    /// Extracts actual wake events (details begin with "DarkWake from" / "Wake from"),
    /// skipping "Wake Requests"/"Assertions" log lines.
    nonisolated static func parse(_ log: String) -> [WakeEvent] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var events: [WakeEvent] = []
        for line in log.components(separatedBy: "\n") {
            guard line.count > 25 else { continue }
            // First 25 chars are "yyyy-MM-dd HH:mm:ss -0700".
            let tsString = String(line.prefix(25))
            guard let ts = fmt.date(from: tsString) else { continue }
            let details = String(line.dropFirst(25))

            let type: String
            if details.contains("DarkWake from") { type = "DarkWake" }
            else if details.contains("Wake from") { type = "Wake" }
            else { continue }

            events.append(WakeEvent(id: nil, timestamp: ts, type: type, reason: categorize(details)))
        }
        return events
    }

    private nonisolated static func categorize(_ d: String) -> String {
        if d.contains("HID Activity") || d.contains(" lid ") || d.contains("multi-touch") { return "User activity" }
        if d.contains("Maintenance") { return "Maintenance" }
        if d.contains("SleepService") { return "Background refresh" }
        if d.contains("NET_FOUND") || d.contains("ARPT") || d.lowercased().contains("wifi") { return "Network" }
        if d.lowercased().contains("bluetooth") || d.contains("BT.") { return "Bluetooth" }
        if d.contains("UserWake") { return "Scheduled app timer" }
        if let r = d.range(of: "rtc/") {
            let token = d[r.upperBound...].prefix { !$0.isWhitespace }
            if !token.isEmpty { return String(token) }
        }
        return "Other"
    }
}
