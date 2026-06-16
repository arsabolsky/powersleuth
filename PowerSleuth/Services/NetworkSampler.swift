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

    static func runNettop() async -> [NettopRow] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // -l 1 = one sample, -x = extended (raw numbers), -P = per-process only
                let output = shell("/usr/bin/nettop", ["-l", "1", "-x", "-P"])
                let rows = parseNettop(output)
                continuation.resume(returning: rows)
            }
        }
    }

    static func parseNettop(_ output: String) -> [NettopRow] {
        var results: [NettopRow] = []
        let lines = output.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        // Find column indices from header
        let header = lines[0].components(separatedBy: "\t")
        guard let bytesInIdx  = header.firstIndex(of: "bytes_in"),
              let bytesOutIdx = header.firstIndex(of: "bytes_out"),
              let retxIdx     = header.firstIndex(of: "re-tx") else { return [] }

        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            let cols = line.components(separatedBy: "\t")
            guard cols.count > max(bytesInIdx, bytesOutIdx, retxIdx) else { continue }

            // First column: "processname.pid"
            let namePid = cols[0]
            let name = String(namePid.split(separator: ".").dropLast().joined(separator: "."))
            guard !name.isEmpty else { continue }

            let bytesIn  = Int64(cols[bytesInIdx])  ?? 0
            let bytesOut = Int64(cols[bytesOutIdx]) ?? 0
            let retx     = Int(cols[retxIdx])       ?? 0

            if bytesIn > 0 || bytesOut > 0 {
                results.append(NettopRow(name: name, bytesIn: bytesIn, bytesOut: bytesOut, retransmits: retx))
            }
        }
        return results.sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
    }
}
