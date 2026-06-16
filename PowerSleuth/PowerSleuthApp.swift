import SwiftUI

@main
struct PowerSleuthApp: App {
    @StateObject private var batteryMonitor     = BatteryMonitor()
    @StateObject private var assertionMonitor   = AssertionMonitor()
    @StateObject private var processSampler     = ProcessSampler()
    @StateObject private var networkSampler     = NetworkSampler()
    @StateObject private var systemCollector    = SystemMetricsCollector()

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
    @State private var showDashboard  = false

    private let coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(onOpenDashboard: { showDashboard = true })
                .environmentObject(batteryMonitor)
                .environmentObject(assertionMonitor)
                .environmentObject(processSampler)
                .environmentObject(systemCollector)
        } label: {
            StatusLabel(snapshot: batteryMonitor.currentSnapshot)
        }
        .menuBarExtraStyle(.window)

        Window("PowerSleuth", id: "dashboard") {
            if showOnboarding {
                OnboardingView(hasSeenOnboarding: $showOnboarding)
            } else {
                DashboardView()
                    .environmentObject(batteryMonitor)
                    .environmentObject(assertionMonitor)
                    .environmentObject(processSampler)
                    .environmentObject(networkSampler)
                    .environmentObject(systemCollector)
            }
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppCoordinator

final class AppCoordinator {
    private var healthTimer: Timer?

    init() {
        try? DatabaseService.shared.pruneOldData()
        sampleHealthIfNeeded()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.sampleHealthIfNeeded()
        }
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
