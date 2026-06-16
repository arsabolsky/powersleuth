import Foundation
import IOKit

/// Samples system-wide CPU, RAM, disk I/O, and real power draw every 30 seconds.
@MainActor
final class SystemMetricsCollector: ObservableObject {
    @Published var current: SystemMetrics?

    private var timer: Timer?
    private var prevDiskReadBytes: Int64 = 0
    private var prevDiskWriteBytes: Int64 = 0
    private var prevSampleTime: Date = Date()
    private var hasDiskBaseline = false

    init() { start() }

    private func start() {
        let configured = UserDefaults.standard.integer(forKey: "monitoring.sampleInterval")
        let interval = configured > 0 ? Double(configured) : 30
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        sample()
    }

    func sample() {
        let cpu = Self.readCPU()
        let ram = Self.readRAM()
        let disk = readDiskDelta()
        let (systemWatts, adapterWatts) = Self.readSystemPower()
        let loadAvg = Self.readLoadAvg()

        var m = SystemMetrics(
            id: nil,
            timestamp: Date(),
            cpuUserPct: cpu.user,
            cpuSysPct: cpu.system,
            cpuIdlePct: cpu.idle,
            ramFreeMb: ram.free,
            ramActiveMb: ram.active,
            ramCompressedMb: ram.compressed,
            ramWiredMb: ram.wired,
            diskReadMbS: disk.readMbS,
            diskWriteMbS: disk.writeMbS,
            systemWatts: systemWatts,
            adapterWatts: adapterWatts,
            loadAvg1m: loadAvg
        )
        current = m
        try? DatabaseService.shared.saveSystemMetrics(&m)
    }

    // MARK: - CPU (host_processor_info)

    static func readCPU() -> (user: Double, system: Double, idle: Double) {
        var cpuCount: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &cpuCount, &infoPtr, &infoCount) == KERN_SUCCESS,
              let ptr = infoPtr else { return (0, 0, 100) }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: ptr),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let buf = UnsafeBufferPointer(start: ptr, count: Int(infoCount))
        var totalUser: Double = 0; var totalSys: Double = 0; var totalIdle: Double = 0
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            totalUser += Double(buf[base + Int(CPU_STATE_USER)])
            totalSys  += Double(buf[base + Int(CPU_STATE_SYSTEM)])
            totalIdle += Double(buf[base + Int(CPU_STATE_IDLE)])
        }
        let total = totalUser + totalSys + totalIdle
        guard total > 0 else { return (0, 0, 100) }
        return (totalUser / total * 100, totalSys / total * 100, totalIdle / total * 100)
    }

    // MARK: - RAM (vm_statistics64)

    static func readRAM() -> (free: Int, active: Int, compressed: Int, wired: Int) {
        var vmstat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmstat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, p, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, 0) }

        // getpagesize() is a function (concurrency-safe); vm_kernel_page_size is a
        // mutable global that Swift 6 rejects as shared mutable state.
        let pageKB = Int(getpagesize()) / 1024
        return (
            free:       Int(vmstat.free_count)        * pageKB / 1024,
            active:     Int(vmstat.active_count)      * pageKB / 1024,
            compressed: Int(vmstat.compressor_page_count) * pageKB / 1024,
            wired:      Int(vmstat.wire_count)        * pageKB / 1024
        )
    }

    // MARK: - Disk I/O (IOBlockStorageDriver cumulative byte counters, delta between calls)
    //
    // Reads true cumulative read/write bytes from IOKit instead of shelling to `iostat`.
    // `iostat -d` reports KB/t, tps, MB/s (aggregate, not read/write split) and the
    // single-sample invocation never terminates — this is both correct and non-blocking.

    private func readDiskDelta() -> (readMbS: Double, writeMbS: Double) {
        let (readBytes, writeBytes) = Self.readCumulativeDiskBytes()

        let now = Date()
        let elapsed = now.timeIntervalSince(prevSampleTime).clamped(to: 1...600)

        defer {
            prevDiskReadBytes = readBytes
            prevDiskWriteBytes = writeBytes
            prevSampleTime = now
            hasDiskBaseline = true
        }

        // First sample only establishes a baseline; no rate yet.
        guard hasDiskBaseline else { return (0, 0) }

        let readDelta  = Double(max(0, readBytes  - prevDiskReadBytes))  / 1_048_576.0 / elapsed
        let writeDelta = Double(max(0, writeBytes - prevDiskWriteBytes)) / 1_048_576.0 / elapsed
        return (readDelta, writeDelta)
    }

    /// Sums "Bytes (Read)" / "Bytes (Write)" from every IOBlockStorageDriver's Statistics dict.
    static func readCumulativeDiskBytes() -> (read: Int64, write: Int64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var totalRead: Int64 = 0
        var totalWrite: Int64 = 0

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as NSDictionary?,
                  let stats = dict["Statistics"] as? NSDictionary else { continue }
            totalRead  += (stats["Bytes (Read)"]  as? Int64) ?? 0
            totalWrite += (stats["Bytes (Write)"] as? Int64) ?? 0
        }
        return (totalRead, totalWrite)
    }

    // MARK: - Real power (BatteryData.SystemPower from IORegistry)

    static func readSystemPower() -> (systemWatts: Double, adapterWatts: Double) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (0, 0) }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let raw = props?.takeRetainedValue() else { return (0, 0) }
        let dict = raw as NSDictionary
        guard let bd = dict["BatteryData"] as? NSDictionary else { return (0, 0) }

        return (bd["SystemPower"] as? Double ?? 0,
                bd["AdapterPower"] as? Double ?? 0)
    }

    // MARK: - Load average

    static func readLoadAvg() -> Double {
        var loads = [Double](repeating: 0, count: 1)
        getloadavg(&loads, 1)
        return loads[0]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(self, range.upperBound))
    }
}
