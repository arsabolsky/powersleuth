import Foundation

/// Enumerates third-party background services (launchd jobs + LaunchAgents/Daemons). These
/// persistent helpers — security agents, sync daemons, updaters, menu-bar tools — are the
/// usual reason one Mac runs hotter than another, so the Compare tab diffs them.
enum ServicesInventory {

    /// Sorted, de-duplicated list of non-Apple service identifiers currently installed/loaded.
    static func capture() -> [String] {
        var set = Set<String>()

        // Loaded launchd jobs.
        for line in shell("/bin/launchctl", ["list"]).components(separatedBy: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            if let label = cols.last.map(String.init), isThirdParty(label) { set.insert(label) }
        }

        // Installed LaunchAgent/Daemon plists.
        let dirs = ["\(NSHomeDirectory())/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let label = String(f.dropLast(6))
                if isThirdParty(label) { set.insert(label) }
            }
        }
        return set.sorted()
    }

    private static func isThirdParty(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        if label.hasPrefix("com.apple.") || label.hasPrefix("application.com.apple.") { return false }
        if label.hasPrefix("0x") || label == "PID" || label == "Label" { return false }
        return true
    }
}
