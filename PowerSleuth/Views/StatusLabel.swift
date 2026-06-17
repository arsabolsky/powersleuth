import SwiftUI

/// Menu-bar icon: a lightning bolt (no text). Stays neutral and tints orange/red only
/// when discharging heavily, so it reads as a glanceable status without a number.
struct StatusLabel: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        Image(systemName: "bolt.fill")
            .foregroundColor(drainColor)
    }

    private var drainColor: Color {
        guard let s = snapshot, !s.isCharging else { return .primary }
        switch DrainLevel.from(watts: s.watts) {
        case .efficient, .moderate: return .primary
        case .elevated:             return .orange
        case .heavy:                return .red
        }
    }
}
