import Foundation

enum DrainLevel: Int, Comparable {
    case efficient = 0   // < 5W
    case moderate  = 1   // 5–12W
    case elevated  = 2   // 12–20W
    case heavy     = 3   // > 20W

    static func < (lhs: DrainLevel, rhs: DrainLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .efficient: return "Efficient"
        case .moderate:  return "Moderate"
        case .elevated:  return "Elevated"
        case .heavy:     return "Heavy"
        }
    }

    var color: String {
        switch self {
        case .efficient: return "green"
        case .moderate:  return "yellow"
        case .elevated:  return "orange"
        case .heavy:     return "red"
        }
    }

    static func from(watts: Double) -> DrainLevel {
        switch watts {
        case ..<5:  return .efficient
        case ..<12: return .moderate
        case ..<20: return .elevated
        default:    return .heavy
        }
    }
}

struct DrainDiagnosis {
    let currentWatts: Double
    let level: DrainLevel
    let culprits: [String]
    let topAssertors: [AssertionSummary]
    let capacityRetentionPct: Double?
    let cycleCount: Int?

    var hasInsights: Bool { !culprits.isEmpty }

    var statusLine: String {
        if currentWatts == 0 {
            return "Charging"
        }
        return String(format: "%.1fW", currentWatts)
    }
}
