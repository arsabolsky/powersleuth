import Foundation

/// Tier 2 "Deep Power Mode": true CPU/GPU/ANE wattage + per-process GPU/CPU time via
/// Apple's `powermetrics` (root-only). No Developer ID → no signed helper, so we use a
/// LaunchDaemon whose lifecycle is tied to a user-owned "run" file via KeepAlive/PathState:
///
///   • First enable installs the daemon (one admin prompt, ever).
///   • Creating the run file makes launchd start powermetrics; deleting it stops powermetrics.
///     → start/stop/quit afterwards need NO prompt and leave no orphaned root process.
///
/// powermetrics streams NUL-separated plist documents to a file we tail (root writes 0644 in
/// our user-owned Caches dir; we read it). stderr is captured for diagnosis.
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
    private var ticksWithoutData = 0

    nonisolated static let label = "com.arsabolsky.powersleuth.deeppower"
    nonisolated static let daemonPlistPath = "/Library/LaunchDaemons/\(label).plist"

    private nonisolated static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PowerSleuth", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private nonisolated static var outURL: URL  { dir.appendingPathComponent("deeppower.plist") }
    private nonisolated static var errURL: URL  { dir.appendingPathComponent("deeppower.err") }
    private nonisolated static var runURL: URL  { dir.appendingPathComponent("deeppower.run") }
    private nonisolated static var cachePlistURL: URL { dir.appendingPathComponent("daemon.plist") }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.daemonPlistPath) }

    // MARK: - Lifecycle

    @discardableResult
    func start() async -> Bool {
        guard available else { lastError = "powermetrics not found on this Mac."; return false }
        guard !isRunning else { return true }
        lastError = nil

        // Fresh stream (we own the dir, so we can unlink root-owned leftovers).
        try? FileManager.default.removeItem(at: Self.outURL)
        try? FileManager.default.removeItem(at: Self.errURL)
        readOffset = 0; carry = Data(); ticksWithoutData = 0

        // Create the run file first so launchd starts powermetrics the moment the daemon
        // loads (KeepAlive/PathState watches this file).
        FileManager.default.createFile(atPath: Self.runURL.path, contents: Data())

        if !isInstalled {
            let ok = await Self.installDaemon()
            guard ok else {
                try? FileManager.default.removeItem(at: Self.runURL)
                lastError = "Admin authorization was denied or the helper install failed."
                return false
            }
        }

        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        return true
    }

    func stop() {
        timer?.invalidate(); timer = nil
        try? FileManager.default.removeItem(at: Self.runURL)   // launchd stops powermetrics
        isRunning = false
    }

    private func tick() async {
        let (newOffset, newCarry, latestSample) = await Self.drain(offset: readOffset, carry: carry)
        readOffset = newOffset
        carry = newCarry
        if let s = latestSample {
            latest = s
            lastError = nil
            ticksWithoutData = 0
        } else {
            ticksWithoutData += 1
            // After ~15s with no data, surface powermetrics' own error output.
            if ticksWithoutData == 3, let err = Self.readError(), !err.isEmpty {
                lastError = "powermetrics: \(err.prefix(200))"
            }
        }
    }

    // MARK: - LaunchDaemon install (one admin prompt, ever)

    private nonisolated static func installDaemon() async -> Bool {
        try? daemonPlistXML().write(toFile: cachePlistURL.path, atomically: true, encoding: .utf8)
        let dst = daemonPlistPath
        let script = [
            "cp '\(cachePlistURL.path)' '\(dst)'",
            "chown root:wheel '\(dst)'",
            "chmod 644 '\(dst)'",
            "launchctl bootout system '\(dst)' 2>/dev/null",
            "launchctl bootstrap system '\(dst)'"
        ].joined(separator: "; ")
        let appleScript = "do shell script \"\(script)\" with administrator privileges"

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", appleScript]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit() } catch { cont.resume(returning: false); return }
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    /// Removes the LaunchDaemon entirely (separate admin prompt). Optional cleanup.
    func uninstall() async {
        stop()
        let dst = Self.daemonPlistPath
        let script = "launchctl bootout system '\(dst)' 2>/dev/null; rm -f '\(dst)'"
        _ = await Self.runOsascriptAdmin(script)
    }

    private nonisolated static func runOsascriptAdmin(_ shellScript: String) async -> Bool {
        let appleScript = "do shell script \"\(shellScript)\" with administrator privileges"
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.launchPath = "/usr/bin/osascript"
                p.arguments = ["-e", appleScript]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit() } catch { cont.resume(returning: false); return }
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    private nonisolated static func daemonPlistXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/powermetrics</string>
            <string>--samplers</string><string>tasks,cpu_power,gpu_power,ane_power</string>
            <string>--show-process-gpu</string>
            <string>--show-process-energy</string>
            <string>-i</string><string>5000</string>
            <string>-f</string><string>plist</string>
          </array>
          <key>RunAtLoad</key><false/>
          <key>KeepAlive</key>
          <dict>
            <key>PathState</key>
            <dict>
              <key>\(runURL.path)</key><true/>
            </dict>
          </dict>
          <key>StandardOutPath</key><string>\(outURL.path)</string>
          <key>StandardErrorPath</key><string>\(errURL.path)</string>
        </dict>
        </plist>
        """
    }

    private nonisolated static func readError() -> String? {
        guard let data = try? Data(contentsOf: errURL) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
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

                // powermetrics -f plist emits NUL-separated documents.
                var working = carry; working.append(chunk)
                var latest: ComponentPowerSample?
                while let nul = working.firstIndex(of: 0x00) {
                    let docData = working.subdata(in: working.startIndex..<nul)
                    if let sample = parseDeepPower(docData) { latest = store(sample) }
                    working.removeSubrange(working.startIndex...nul)
                }
                cont.resume(returning: (newOffset, working, latest))
            }
        }
    }

    private nonisolated static func store(_ s: DeepPowerSample) -> ComponentPowerSample {
        var comp = ComponentPowerSample(id: nil, timestamp: s.timestamp,
                                        cpuWatts: s.cpuWatts, gpuWatts: s.gpuWatts, aneWatts: s.aneWatts)
        try? DatabaseService.shared.saveComponentPower(&comp)

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

    /// Parses one `powermetrics -f plist` document. Power is mW → W. Keys vary by chip/OS,
    /// so every lookup is defensive with fallbacks + default 0.
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
                let gpuMs = (t["gputime_ms_per_s"] as? NSNumber)?.doubleValue ?? 0
                let ei    = (t["energy_impact"] as? NSNumber)?.doubleValue ?? 0
                tasks.append(.init(pid: pid, name: name, cpuMsPerSec: cpuMs, gpuMsPerSec: gpuMs, energyImpact: ei))
            }
        }
        return DeepPowerSample(timestamp: Date(), cpuWatts: cpuW, gpuWatts: gpuW, aneWatts: aneW, tasks: tasks)
    }
}
