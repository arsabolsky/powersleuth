import Foundation

/// Runs `nettop` every 5 minutes and captures per-process network I/O deltas.
@MainActor
final class NetworkSampler: ObservableObject {
    @Published var topNetworkUsers: [NetworkAggregation] = []

    private var timer: Timer?
    private var prevBytesIn:  [String: Int64] = [:]
    private var prevBytesOut: [String: Int64] = [:]

    init() { start() }
    deinit { timer?.invalidate() }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        Task { await sample() }
    }

    func sample() async {
        let rows = await Self.runNettop()
        guard !rows.isEmpty else { return }

        var deltas: [NetworkSample] = []
        let now = Date()

        for row in rows {
            let key = row.name
            let prevIn  = prevBytesIn[key]  ?? row.bytesIn
            let prevOut = prevBytesOut[key] ?? row.bytesOut

            let inDelta  = max(0, row.bytesIn  - prevIn)
            let outDelta = max(0, row.bytesOut - prevOut)

            prevBytesIn[key]  = row.bytesIn
            prevBytesOut[key] = row.bytesOut

            if inDelta > 0 || outDelta > 0 {
                deltas.append(NetworkSample(
                    id: nil, timestamp: now, processName: key,
                    bytesInDelta: inDelta, bytesOutDelta: outDelta,
                    retransmits: row.retransmits
                ))
            }
        }

        if !deltas.isEmpty {
            try? DatabaseService.shared.saveNetworkSamples(deltas)
        }

        let aggs = (try? DatabaseService.shared.fetchNetworkAggregations(
            since: Date().addingTimeInterval(-3600 * 24), limit: 20)) ?? []
        topNetworkUsers = aggs
    }

    // MARK: - nettop parser

    struct NettopRow: Sendable {
        let name: String
        let bytesIn: Int64
        let bytesOut: Int64
        let retransmits: Int
    }

    nonisolated static func runNettop() async -> [NettopRow] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // -P = per-process, -L 1 = one snapshot, -x = raw byte counts,
                // -J = emit ONLY these columns as CSV (deterministic, no padding/tabs).
                let output = shell("/usr/bin/nettop",
                    ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out,re-tx"])
                let rows = parseNettop(output)
                continuation.resume(returning: rows)
            }
        }
    }

    /// Parses nettop `-J` CSV output. Each line is:  `name.pid,bytes_in,bytes_out,re-tx,`
    /// with a leading header row (`,bytes_in,bytes_out,re-tx,`). nettop emits commas, not tabs.
    nonisolated static func parseNettop(_ output: String) -> [NettopRow] {
        var results: [NettopRow] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard !line.isEmpty else { continue }
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 3 else { continue }

            // First column: "processname.pid" — drop the trailing numeric pid component.
            let namePid = cols[0]
            guard !namePid.isEmpty, Int(namePid.split(separator: ".").last ?? "") != nil else { continue }
            let name = String(namePid.split(separator: ".").dropLast().joined(separator: "."))
            guard !name.isEmpty else { continue }

            let bytesIn  = Int64(cols[1]) ?? 0
            let bytesOut = Int64(cols[2]) ?? 0
            let retx     = cols.count > 3 ? (Int(cols[3]) ?? 0) : 0

            results.append(NettopRow(name: name, bytesIn: bytesIn, bytesOut: bytesOut, retransmits: retx))
        }
        return results.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
    }
}
