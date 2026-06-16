import Foundation
import IOKit.ps
import IOKit
import Combine

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var currentSnapshot: BatterySnapshot?

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?

    init() {
        startMonitoring()
    }

    private func startMonitoring() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        // The run loop source is attached to the main run loop, so the callback fires
        // on the main thread — assumeIsolated lets us hop back into MainActor safely.
        let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.sample() }
        }, context)
        runLoopSource = src?.takeRetainedValue()

        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }

        // Fallback poll; interval is user-configurable (Settings → Monitoring).
        let configured = UserDefaults.standard.integer(forKey: "monitoring.sampleInterval")
        let interval = configured > 0 ? Double(configured) : 30
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        sample()
    }

    func sample() {
        guard let snapshot = Self.readSnapshot() else { return }
        currentSnapshot = snapshot
        var s = snapshot
        try? DatabaseService.shared.saveSnapshot(&s)
    }

    // MARK: - IOPowerSources + IORegistry

    nonisolated static func readSnapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let rawList = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
        else { return nil }

        let array = rawList as NSArray
        guard array.count > 0 else { return nil }
        let src = array[0] as CFTypeRef

        // IOPSGetPowerSourceDescription is a "Get" function (+0, caller must NOT release).
        // Using takeRetainedValue() here over-releases the dictionary and crashes (EXC_BAD_ACCESS).
        guard let rawDesc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
        else { return nil }

        let desc = rawDesc as NSDictionary

        let percentage  = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let isCharging  = (desc[kIOPSIsChargingKey] as? Bool) ?? ((desc[kIOPSIsChargingKey] as? Int) == 1)
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? "Unknown"

        // IORegistry has more precise voltage, amperage, and temperature
        let reg = readSmartBatteryDict() ?? [:]
        let voltageMv    = reg["Voltage"] as? Int ?? 0
        let amperageMa   = reg["InstantAmperage"] as? Int ?? 0
        let rawTemp      = reg["Temperature"] as? Double ?? 0
        // Temperature is in hundredths of a degree Celsius on most Macs
        let temperatureC = rawTemp > 1000 ? rawTemp / 100.0 : rawTemp

        let thermalState = ProcessInfo.processInfo.thermalState.rawValue
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let systemWatts  = (reg["BatteryData"] as? NSDictionary)?["SystemPower"] as? Double ?? 0

        return BatterySnapshot(
            id: nil,
            timestamp: Date(),
            percentage: percentage,
            voltageMv: voltageMv,
            amperageMa: amperageMa,
            temperatureC: temperatureC,
            isCharging: isCharging,
            powerSource: powerSource,
            thermalState: thermalState,
            lowPowerMode: lowPowerMode,
            systemWatts: systemWatts
        )
    }

    // MARK: - IORegistry (AppleSmartBattery)

    nonisolated static func readSmartBatteryDict() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let raw = props?.takeRetainedValue()
        else { return nil }
        return raw as NSDictionary as? [String: Any]
    }

    // Returns cycle count and raw mAh capacities for health tracking.
    // Uses AppleRawMaxCapacity (mAh) not MaxCapacity (which is % on modern Macs).
    nonisolated static func readHealthInfo() -> (cycleCount: Int, designMah: Int, maxMah: Int)? {
        guard let dict = readSmartBatteryDict() else { return nil }
        let cycles = dict["CycleCount"] as? Int ?? 0
        let design = dict["DesignCapacity"] as? Int ?? 0
        let maxCap = dict["AppleRawMaxCapacity"] as? Int
            ?? dict["NominalChargeCapacity"] as? Int
            ?? (dict["MaxCapacity"] as? Int ?? 0)
        guard design > 0, maxCap > 100 else { return nil }
        return (cycleCount: cycles, designMah: design, maxMah: maxCap)
    }
}
