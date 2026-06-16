import Foundation
import AppKit

/// Tracks sleep/awake sessions from NSWorkspace notifications, which are delivered
/// on the main thread — so this type is MainActor-isolated.
@MainActor
final class SessionTracker {
    static let shared = SessionTracker()

    private var openSessionId: Int64?
    private var openSessionStart: Date?
    private var openSessionStartPct: Int = 0
    private var openSessionType: SessionType = .awake

    private init() {
        observeSleepWake()
        openAwakeSession()
    }

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(onWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func onWillSleep() {
        closeCurrentSession()
        openSession(type: .sleep)
    }

    @objc private func onDidWake() {
        closeCurrentSession()
        openSession(type: .awake)
    }

    private func openSession(type: SessionType) {
        let pct = BatteryMonitor.readSnapshot()?.percentage ?? 0
        let now = Date()
        openSessionStart = now
        openSessionStartPct = pct
        openSessionType = type

        var session = DrainSession(
            id: nil,
            startTimestamp: now,
            endTimestamp: nil,
            sessionType: type,
            startPercentage: pct,
            endPercentage: nil,
            avgWatts: nil,
            drainPctPerHour: nil
        )
        try? DatabaseService.shared.openSession(&session)
        openSessionId = session.id
    }

    private func openAwakeSession() {
        // Close any dangling open session from last run
        if let dangling = try? DatabaseService.shared.fetchOpenSession(), let sid = dangling.id {
            let now = Date()
            let pct = BatteryMonitor.readSnapshot()?.percentage ?? dangling.startPercentage
            let hours = now.timeIntervalSince(dangling.startTimestamp) / 3600.0
            let drainRate = hours > 0 ? Double(dangling.startPercentage - pct) / hours : 0
            try? DatabaseService.shared.closeSession(
                id: sid,
                endTimestamp: now,
                endPercentage: pct,
                avgWatts: 0,
                drainPctPerHour: drainRate
            )
        }
        openSession(type: .awake)
    }

    private func closeCurrentSession() {
        guard let sid = openSessionId,
              let startDate = openSessionStart else { return }

        let endPct = BatteryMonitor.readSnapshot()?.percentage ?? openSessionStartPct
        let now = Date()
        let hours = now.timeIntervalSince(startDate) / 3600.0
        let drainRate = hours > 0 ? Double(openSessionStartPct - endPct) / hours : 0

        // Compute avg watts from recorded snapshots during this session
        let snapshots = (try? DatabaseService.shared.fetchSnapshots(since: startDate)) ?? []
        let watts = snapshots.filter { !$0.isCharging }.map(\.watts)
        let avgWatts = watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count)

        try? DatabaseService.shared.closeSession(
            id: sid,
            endTimestamp: now,
            endPercentage: endPct,
            avgWatts: avgWatts,
            drainPctPerHour: drainRate
        )

        openSessionId = nil
        openSessionStart = nil
    }
}
