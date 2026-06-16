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
                OnboardingView(showOnboarding: $showOnboarding)
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

@MainActor
final class AppCoordinator {
    private var dailyTimer: Timer?
    private var alertTimer: Timer?

    init() {
        // Register default values so @AppStorage (SettingsView) and raw UserDefaults
        // reads (NarrativeEngine) agree. Without this, AI features read `false` until
        // the user first toggles them, even though the UI shows them ON.
        UserDefaults.standard.register(defaults: [
            "ai.enableSummary": true,
            "ai.enableFindings": true,
            "ai.useAppleIntelligence": true,
            "ai.useOllama": true,
            "monitoring.sampleInterval": 30,
            "monitoring.retentionDays": 30,
            "deepPower.enabled": false
        ])

        // Resume Deep Power Mode if the user left it on (re-prompts for admin once).
        if UserDefaults.standard.bool(forKey: "deepPower.enabled") {
            Task { await DeepPowerSampler.shared.start() }
        }
        // Make sure the privileged powermetrics process is stopped when we quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeepPowerSampler.shared.stop() }
        }

        pruneNow()
        sampleHealthIfNeeded()
        DrainNotifier.requestAuthorizationIfEnabled()

        // Health sampling + pruning run daily (not just at launch — important for an
        // always-on app, otherwise the DB grows unbounded between launches).
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleHealthIfNeeded()
                self?.pruneNow()
            }
        }
        // High-drain check every 2 minutes (no-op unless the alert is enabled).
        alertTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in DrainNotifier.checkAndNotify() }
        }
        _ = SessionTracker.shared
    }

    private func pruneNow() {
        let days = UserDefaults.standard.integer(forKey: "monitoring.retentionDays")
        try? DatabaseService.shared.pruneOldData(retentionDays: days > 0 ? days : 30)
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
