import SwiftUI

@main
struct PowerSleuthApp: App {
    @StateObject private var batteryMonitor = BatteryMonitor()
    @StateObject private var assertionMonitor = AssertionMonitor()

    private let coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(batteryMonitor)
                .environmentObject(assertionMonitor)
        } label: {
            StatusLabel(snapshot: batteryMonitor.currentSnapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Holds long-lived timers and one-time startup tasks outside the SwiftUI lifecycle.
final class AppCoordinator {
    private var healthTimer: Timer?

    init() {
        try? DatabaseService.shared.pruneOldData()
        sampleHealthIfNeeded()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.sampleHealthIfNeeded()
        }
        // Kick off session tracker
        _ = SessionTracker.shared
    }

    private func sampleHealthIfNeeded() {
        guard let info = BatteryMonitor.readHealthInfo() else { return }
        try? DatabaseService.shared.saveBatteryHealth(
            cycleCount: info.cycleCount,
            designCapacityMah: info.designMah,
            maxCapacityMah: info.maxMah
        )
    }
}
