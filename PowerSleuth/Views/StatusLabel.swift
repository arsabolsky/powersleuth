import SwiftUI

struct StatusLabel: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: batteryIcon)
                .foregroundColor(drainColor)
            Text(labelText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(drainColor)
        }
    }

    private var labelText: String {
        guard let s = snapshot else { return "—" }
        if s.isCharging { return "charging" }
        if s.watts == 0 { return "\(s.percentage)%" }
        return String(format: "%.1fW", s.watts)
    }

    private var batteryIcon: String {
        guard let s = snapshot else { return "battery.0" }
        switch s.percentage {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default:    return "battery.0"
        }
    }

    private var drainColor: Color {
        guard let s = snapshot, !s.isCharging else { return .primary }
        switch DrainLevel.from(watts: s.watts) {
        case .efficient: return .primary
        case .moderate:  return .primary
        case .elevated:  return .orange
        case .heavy:     return .red
        }
    }
}
