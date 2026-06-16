import Foundation
import IOKit

/// Samples system-wide CPU, RAM, disk I/O, and real power draw every 30 seconds.
@MainActor
final class SystemMetricsCollector: ObservableObject {
    @Published var current: SystemMetrics?

    private var timer: Timer?
    private var prevCPUInfo: [Int32] = []
    private var prevDiskRead: Double = 0
    private var prevDiskWrite: Double = 0
    private var prevSampleTime: Date = Date()

    init() { start() }
    deinit { timer?.invalidate() }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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

        let pageKB = Int(vm_kernel_page_size) / 1024
        return (
            free:       Int(vmstat.free_count)        * pageKB / 1024,
            active:     Int(vmstat.active_count)      * pageKB / 1024,
            compressed: Int(vmstat.compressor_page_count) * pageKB / 1024,
            wired:      Int(vmstat.wire_count)        * pageKB / 1024
        )
    }

    // MARK: - Disk I/O (iostat parse, delta between calls)

    private func readDiskDelta() -> (readMbS: Double, writeMbS: Double) {
        let output = shell("/usr/sbin/iostat", ["-d", "-n", "1", "1"])
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 3 else { return (0, 0) }
        let parts = lines[2].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let readKB = Double(parts[1]),
              let writeKB = Double(parts[2]) else { return (0, 0) }

        let now = Date()
        let elapsed = now.timeIntervalSince(prevSampleTime).clamped(to: 1...120)
        let readDelta  = max(0, readKB  - prevDiskRead)  / 1024.0 / elapsed
        let writeDelta = max(0, writeKB - prevDiskWrite) / 1024.0 / elapsed

        prevDiskRead  = readKB
        prevDiskWrite = writeKB
        prevSampleTime = now

        return (readDelta, writeDelta)
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
