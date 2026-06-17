import SwiftUI

/// Menu-bar icon: the battery emoji, no text. Click it for the live details popover.
struct StatusLabel: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        Text("🔋")
    }
}
