import Foundation
import ServiceManagement
import UserNotifications

/// Launch-at-login via SMAppService (macOS 13+). Registers the main app itself.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success; on failure the caller should revert its UI to `isEnabled`.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("PowerSleuth: login item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}

/// Posts a local notification when sustained discharge exceeds the user's threshold.
@MainActor
enum DrainNotifier {
    private static var lastAlert: Date?

    static func requestAuthorizationIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "monitoring.highDrainAlertEnabled") else { return }
        requestAuthorization()
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Checks the last 5 minutes of discharge and notifies if the average exceeds the
    /// configured threshold. Rate-limited to once per 30 minutes.
    static func checkAndNotify() {
        guard UserDefaults.standard.bool(forKey: "monitoring.highDrainAlertEnabled") else { return }
        let stored = UserDefaults.standard.double(forKey: "monitoring.highDrainAlertWatts")
        let threshold = stored > 0 ? stored : 20

        let snapshots = (try? DatabaseService.shared.fetchRecentSnapshots(minutes: 5)) ?? []
        let watts = snapshots.filter { !$0.isCharging }.map(\.watts).filter { $0 > 0 }
        guard watts.count >= 5 else { return }  // require ~5 min of 30s samples (sustained)

        let avg = watts.reduce(0, +) / Double(watts.count)
        guard avg > threshold else { return }

        if let last = lastAlert, Date().timeIntervalSince(last) < 1800 { return }
        lastAlert = Date()

        let content = UNMutableNotificationContent()
        content.title = "High battery drain"
        content.body = String(format: "Averaging %.1f W over the last 5 min (threshold %.0f W). Open PowerSleuth to see what's responsible.", avg, threshold)
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "drain-alert", content: content, trigger: nil)
        )
    }
}
