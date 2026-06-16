import Foundation

/// Tier 2 "Deep Power Mode": runs a long-lived, privileged `powermetrics` (one admin
/// prompt per session) that streams plist samples to a file we tail. Gives true CPU/GPU/ANE
/// wattage and per-process GPU/CPU time — impossible without elevated privileges.
///
/// No Developer ID is available, so SMJobBless/SMAppService daemons aren't viable. Instead a
/// small shell script is run via `osascript ... with administrator privileges`; it kills any
/// prior instance, starts powermetrics, and a watcher kills it when a user-writable STOP file
/// appears (so we can stop without a second prompt). Files live in ~/Library/Caches/PowerSleuth
/// (no spaces → simple quoting; transient streaming data).
@MainActor
final class DeepPowerSampler: ObservableObject {
    static let shared = DeepPowerSampler()
    private init() {}

    @Published var isRunning = false
    @Published var available = FileManager.default.isExecutableFile(atPath: "/usr/bin/powermetrics")
    @Published var lastError: String?
    @Published var latest: ComponentPowerSample?

    private var timer: Timer?
    private var readOffset: UInt64 = 0
    private var carry = Data()

    private nonisolated static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PowerSleuth", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private nonisolated static var outURL: URL { dir.appendingPathComponent("deeppower.plist") }
    private nonisolated static var stopURL: URL { dir.appendingPathComponent("deeppower.stop") }
    private nonisolated static var scriptURL: URL { dir.appendingPathComponent("deeppower.sh") }

    // MARK: - Lifecycle

    /// Triggers the admin prompt and starts streaming. Returns false if unavailable/denied.
    @discardableResult
    func start() async -> Bool {
        guard available else { lastError = "powermetrics not found"; return false }
        guard !isRunning else { return true }
        lastError = nil

        let ok = await Self.launchPrivileged()
        guard ok else {
            lastError = "Admin authorization was denied or cancelled."
            isRunning = false
            return false
        }
        readOffset = 0
        carry = Data()
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        // Signal the privileged watcher to kill powermetrics (no second admin prompt).
        FileManager.default.createFile(atPath: Self.stopURL.path, contents: Data())
        isRunning = false
    }

    private func tick() async {
        let (newOffset, newCarry, latestSample) = await Self.drain(offset: readOffset, carry: carry)
        readOffset = newOffset
        carry = newCarry
        if let s = latestSample { latest = s }
    }

    // MARK: - Privileged launch

    private nonisolated static func launchPrivileged() async -> Bool {
        let out = outURL.path, stop = stopURL.path, script = scriptURL.path
        let body = """
        #!/bin/sh
        OUT="\(out)"
        STOP="\(stop)"
        pkill -f 'powermetrics --samplers cpu_power' 2>/dev/null
        rm -f "$STOP"
        nohup powermetrics --samplers cpu_power,gpu_power,ane_power,tasks -i 5000 -f plist > "$OUT" 2>/dev/null &
        PM=$!
        nohup sh -c "while kill -0 $PM 2>/dev/null; do if [ -f \\"$STOP\\" ]; then kill $PM; break; fi; sleep 2; done" >/dev/null 2>&1 &
        exit 0
        """
        try? body.write(toFile: script, atomically: true, encoding: .utf8)

        let appleScript = "do shell script \"/bin/sh '\(script)'\" with administrator privileges"
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", appleScript]
                p.standardError = Pipe(); p.standardOutput = Pipe()
                do { try p.run(); p.waitUntilExit() } catch { cont.resume(returning: false); return }
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    // MARK: - Tail + parse + store (background)

    private nonisolated static func drain(offset: UInt64, carry: Data) async -> (UInt64, Data, ComponentPowerSample?) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                guard let fh = try? FileHandle(forReadingFrom: outURL) else {
                    cont.resume(returning: (offset, carry, nil)); return
                }
                defer { try? fh.close() }
                try? fh.seek(toOffset: offset)
                let chunk = (try? fh.readToEnd()) ?? Data()
                let newOffset = offset + UInt64(chunk.count)

                var buffer = carry; buffer.append(chunk)
                let terminator = Data("</plist>".utf8)
                var latest: ComponentPowerSample?
                var searchStart = buffer.startIndex

                while let r = buffer.range(of: terminator, in: searchStart..<buffer.endIndex) {
                    let docEnd = r.upperBound
                    let docData = buffer.subdata(in: buffer.startIndex..<docEnd)
                    if let sample = parseDeepPower(docData) {
                        latest = store(sample)
                    }
                    // Drop the consumed document from the buffer.
                    buffer.removeSubrange(buffer.startIndex..<docEnd)
                    searchStart = buffer.startIndex
                }
                cont.resume(returning: (newOffset, buffer, latest))
            }
        }
    }

    /// Persists one sample (component row + notable per-process rows) and returns the component row.
    private nonisolated static func store(_ s: DeepPowerSample) -> ComponentPowerSample {
        var comp = ComponentPowerSample(id: nil, timestamp: s.timestamp,
                                        cpuWatts: s.cpuWatts, gpuWatts: s.gpuWatts, aneWatts: s.aneWatts)
        try? DatabaseService.shared.saveComponentPower(&comp)

        // Keep GPU users + top energy tasks (avoid storing hundreds of idle tasks).
        let notable = s.tasks
            .filter { $0.gpuMsPerSec > 0 || $0.energyImpact > 1 }
            .sorted { a, b in
                if a.gpuMsPerSec != b.gpuMsPerSec { return a.gpuMsPerSec > b.gpuMsPerSec }
                return a.energyImpact > b.energyImpact
            }
            .prefix(30)
        let rows = notable.map {
            ProcessPowerSample(id: nil, timestamp: s.timestamp, pid: $0.pid, name: $0.name,
                               cpuMsPerSec: $0.cpuMsPerSec, gpuMsPerSec: $0.gpuMsPerSec, energyImpact: $0.energyImpact)
        }
        if !rows.isEmpty { try? DatabaseService.shared.saveProcessPower(rows) }
        return comp
    }

    /// Parses one `powermetrics -f plist` document. Power is reported in mW → convert to W.
    /// Key names vary by chip/OS, so every lookup is defensive with fallbacks + default 0.
    nonisolated static func parseDeepPower(_ data: Data) -> DeepPowerSample? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }

        func mWtoW(_ v: Any?) -> Double { ((v as? NSNumber)?.doubleValue ?? 0) / 1000.0 }
        let proc = dict["processor"] as? [String: Any] ?? [:]
        let gpu  = dict["GPU"] as? [String: Any] ?? [:]

        let cpuW = mWtoW(proc["cpu_power"] ?? proc["package_watts"])
        let gpuW = mWtoW(proc["gpu_power"] ?? gpu["gpu_power"] ?? gpu["gpu_energy"])
        let aneW = mWtoW(proc["ane_power"])

        var tasks: [DeepPowerSample.TaskPower] = []
        if let arr = dict["tasks"] as? [[String: Any]] {
            for t in arr {
                guard let pid = (t["pid"] as? NSNumber)?.intValue else { continue }
                let name = (t["name"] as? String) ?? "pid \(pid)"
                let cpuMs = (t["cputime_ms_per_s"] as? NSNumber)?.doubleValue ?? 0
                let gpuMs = (t["gputime_ms_per_s"] as? NSNumber)?.doubleValue
                    ?? (t["gputime_ms_per_s_per_s"] as? NSNumber)?.doubleValue ?? 0
                let ei    = (t["energy_impact"] as? NSNumber)?.doubleValue ?? 0
                tasks.append(.init(pid: pid, name: name, cpuMsPerSec: cpuMs, gpuMsPerSec: gpuMs, energyImpact: ei))
            }
        }
        return DeepPowerSample(timestamp: Date(), cpuWatts: cpuW, gpuWatts: gpuW, aneWatts: aneW, tasks: tasks)
    }
}
