import Foundation

/// Reads true CPU / GPU / ANE power from Apple's private IOReport API — **no admin required**
/// (the same mechanism macmon uses). Subscribes once to the "Energy Model" channel group and
/// computes watts from the energy delta between samples. All symbols are resolved at runtime
/// via dlsym, so there's no link-time dependency on the private library.
///
/// Verified on Apple Silicon: aggregate channels "CPU Energy", "GPU", "ANE" report energy in
/// mJ; watts = energy_in_joules / elapsed_seconds.
final class IOReportPower {

    // C function signatures (resolved via dlsym).
    private typealias CopyChannelsInGroup =
        @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SimpleGetInteger =
        @convention(c) (CFDictionary, Int32) -> Int64
    private typealias ChannelGetUnitLabel =
        @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let getInteger: SimpleGetInteger
    private let getUnit: ChannelGetUnitLabel?
    private let subscription: UnsafeMutableRawPointer
    private let subbedChannels: CFMutableDictionary

    private var prevSample: CFDictionary?
    private var prevTime = Date()

    /// nil if IOReport isn't available (then component power is simply unavailable; no crash).
    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
        guard let copyP = sym("IOReportCopyChannelsInGroup"),
              let subP  = sym("IOReportCreateSubscription"),
              let samP  = sym("IOReportCreateSamples"),
              let delP  = sym("IOReportCreateSamplesDelta"),
              let intP  = sym("IOReportSimpleGetIntegerValue") else { return nil }

        let copyChannels = unsafeBitCast(copyP, to: CopyChannelsInGroup.self)
        let createSub    = unsafeBitCast(subP, to: CreateSubscription.self)
        self.createSamples = unsafeBitCast(samP, to: CreateSamples.self)
        self.createDelta   = unsafeBitCast(delP, to: CreateSamplesDelta.self)
        self.getInteger    = unsafeBitCast(intP, to: SimpleGetInteger.self)
        self.getUnit       = sym("IOReportChannelGetUnitLabel").map { unsafeBitCast($0, to: ChannelGetUnitLabel.self) }

        guard let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
            else { return nil }
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, channels, &subbedOut, 0, nil),
              let subbed = subbedOut?.takeRetainedValue() else { return nil }
        self.subscription = sub
        self.subbedChannels = subbed
    }

    /// Returns average CPU/GPU/ANE/display watts since the previous call (nil on the first
    /// call, while it establishes a baseline). Display = DISP + DISPEXT channels.
    func sample() -> (cpuW: Double, gpuW: Double, aneW: Double, displayW: Double)? {
        guard let cur = createSamples(subscription, subbedChannels, nil)?.takeRetainedValue() else { return nil }
        defer { prevSample = cur; prevTime = Date() }
        guard let prev = prevSample else { return nil }

        let elapsed = Date().timeIntervalSince(prevTime)
        guard elapsed > 0.05 else { return nil }
        guard let delta = createDelta(prev, cur, nil)?.takeRetainedValue() else { return nil }

        guard let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        var cpuJ = 0.0, gpuJ = 0.0, aneJ = 0.0, dispJ = 0.0
        for ch in channels {
            guard let legend = ch["LegendChannel"] as? [Any], legend.count >= 3,
                  let name = legend[2] as? String else { continue }
            guard name == "CPU Energy" || name == "GPU" || name == "ANE"
                    || name == "DISP" || name == "DISPEXT" else { continue }

            let raw = getInteger(ch as CFDictionary, 0)
            let unit = getUnit?(ch as CFDictionary)?.takeUnretainedValue() as String?
            let joules = Double(raw) * Self.joulesPerUnit(unit)
            switch name {
            case "CPU Energy":     cpuJ += joules
            case "GPU":            gpuJ += joules
            case "ANE":            aneJ += joules
            case "DISP", "DISPEXT": dispJ += joules
            default: break
            }
        }
        return (cpuJ / elapsed, gpuJ / elapsed, aneJ / elapsed, dispJ / elapsed)
    }

    private static func joulesPerUnit(_ unit: String?) -> Double {
        switch unit {
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        case "nJ": return 1e-9
        case "pJ": return 1e-12
        case "J":  return 1
        default:   return 1e-3   // Energy Model aggregates are mJ on Apple Silicon
        }
    }
}
