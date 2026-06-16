import Foundation
import IOKit.ps
import IOKit
import Combine

final class BatteryMonitor: ObservableObject {
    @Published var currentSnapshot: BatterySnapshot?

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().sample()
        }, context)
        runLoopSource = src?.takeRetainedValue()

        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }

        // Fallback: poll every 30 seconds in case notifications miss an update
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func sample() {
        guard let snapshot = Self.readSnapshot() else { return }
        DispatchQueue.main.async { self.currentSnapshot = snapshot }
        var s = snapshot
        try? DatabaseService.shared.saveSnapshot(&s)
    }

    // MARK: - IOPowerSources + IORegistry

    static func readSnapshot() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let rawList = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
        else { return nil }

        let array = rawList as NSArray
        guard array.count > 0 else { return nil }
        let src = array[0] as CFTypeRef

        guard let rawDesc = IOPSGetPowerSourceDescription(blob, src)?.takeRetainedValue()
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
            lowPowerMode: lowPowerMode
        )
    }

    // MARK: - IORegistry (AppleSmartBattery)

    static func readSmartBatteryDict() -> [String: Any]? {
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
    static func readHealthInfo() -> (cycleCount: Int, designMah: Int, maxMah: Int)? {
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
