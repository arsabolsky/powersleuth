import Foundation

/// Runs `top` every 60 seconds and captures per-process CPU%, memory, and energy impact.
/// The energy impact score is the same metric Activity Monitor's "Energy" column shows.
@MainActor
final class ProcessSampler: ObservableObject {
    @Published var topConsumers: [ProcessAggregation] = []

    private var timer: Timer?

    init() { start() }
    deinit { timer?.invalidate() }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        Task { await sample() }
    }

    func sample() async {
        let samples = await Self.runTopSample()
        guard !samples.isEmpty else { return }
        try? DatabaseService.shared.saveProcessSamples(samples)

        let aggs = (try? DatabaseService.shared.fetchProcessAggregations(
            since: Date().addingTimeInterval(-3600), limit: 30)) ?? []
        topConsumers = aggs
    }

    // MARK: - top parser

    /// Runs `top -l 2 -s 1` — takes two 1-second samples; the second is accurate.
    /// Returns the top 30 processes sorted by energy impact.
    nonisolated static func runTopSample() async -> [ProcessSample] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let output = shell("/usr/bin/top", ["-l", "2", "-s", "1",
                    "-stats", "pid,command,cpu,mem,power,state",
                    "-o", "power", "-n", "30"])
                let samples = parseTopOutput(output)
                continuation.resume(returning: samples)
            }
        }
    }

    nonisolated static func parseTopOutput(_ output: String) -> [ProcessSample] {
        // `top -l 2` prints two full blocks; the second sample carries accurate CPU/power.
        // Find the LAST header line ("PID  COMMAND ...") and parse the rows after it.
        let allLines = output.components(separatedBy: "\n")
        guard let headerIdx = allLines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }

        var results: [ProcessSample] = []
        let now = Date()

        for line in allLines[(headerIdx + 1)...] {
            // The COMMAND column may contain spaces ("Google Chrome He", "Claude Helper (R"),
            // so parse the fixed trailing columns from the END:
            //   PID  <command with spaces>  %CPU  MEM  POWER  STATE
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6, let pid = Int(parts[0]) else { continue }

            let state   = String(parts[parts.count - 1])
            let powerStr = String(parts[parts.count - 2])
            let memStr   = String(parts[parts.count - 3])
            let cpuStr   = String(parts[parts.count - 4]).replacingOccurrences(of: "%", with: "")
            let name     = parts[1..<(parts.count - 4)].joined(separator: " ")

            guard let cpu = Double(cpuStr), !name.isEmpty else { continue }

            results.append(ProcessSample(
                id: nil, timestamp: now, pid: pid, name: name,
                cpuPct: cpu, memMb: parseMem(memStr),
                energyImpact: Double(powerStr) ?? 0, state: state
            ))
        }

        return results.sorted { $0.energyImpact > $1.energyImpact }
    }

    /// Parses `top`'s MEM column (e.g. "589M-", "1296M+", "7185K", "1.2G"). The trailing
    /// "+"/"-" is a compression-change indicator and must be stripped before the unit.
    nonisolated static func parseMem(_ s: String) -> Double {
        let trimmed = s.replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "-", with: "")
        let lower = trimmed.lowercased()
        if lower.hasSuffix("g"), let v = Double(lower.dropLast()) { return v * 1024 }
        if lower.hasSuffix("m"), let v = Double(lower.dropLast()) { return v }
        if lower.hasSuffix("k"), let v = Double(lower.dropLast()) { return v / 1024 }
        if lower.hasSuffix("b"), let v = Double(lower.dropLast()) { return v / 1_048_576 }
        return Double(trimmed) ?? 0
    }
}

// MARK: - Shell helper (shared)

func shell(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.launchPath = path
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
