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
    static func runTopSample() async -> [ProcessSample] {
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

    // swiftlint:disable:next cyclomatic_complexity
    static func parseTopOutput(_ output: String) -> [ProcessSample] {
        // top -l 2 produces two full blocks. We want the SECOND block (after the second header).
        let blocks = output.components(separatedBy: "PID")
        guard blocks.count >= 3 else { return [] }      // at least 2 header splits
        let secondBlock = "PID" + blocks[blocks.count - 1]

        var results: [ProcessSample] = []
        let lines = secondBlock.components(separatedBy: "\n").dropFirst()  // skip header line
        let now = Date()

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5 else { continue }

            guard let pid = Int(parts[0]) else { continue }
            let name = String(parts[1])
            let cpuStr = String(parts[2]).replacingOccurrences(of: "%", with: "")
            let memStr = String(parts[3])
            let powerStr = String(parts[4])
            let state = parts.count > 5 ? String(parts[5]) : "sleeping"

            guard let cpu = Double(cpuStr) else { continue }
            let mem = parseMem(memStr)
            let power = Double(powerStr) ?? 0

            results.append(ProcessSample(
                id: nil, timestamp: now, pid: pid, name: name,
                cpuPct: cpu, memMb: mem, energyImpact: power, state: state
            ))
        }

        return results.sorted { $0.energyImpact > $1.energyImpact }
    }

    private static func parseMem(_ s: String) -> Double {
        let lower = s.lowercased()
        if lower.hasSuffix("g"), let v = Double(lower.dropLast()) { return v * 1024 }
        if lower.hasSuffix("m"), let v = Double(lower.dropLast()) { return v }
        if lower.hasSuffix("k"), let v = Double(lower.dropLast()) { return v / 1024 }
        return Double(s) ?? 0
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
