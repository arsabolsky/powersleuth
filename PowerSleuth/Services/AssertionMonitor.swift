import Foundation
import Combine

@MainActor
final class AssertionMonitor: ObservableObject {
    @Published var activeAssertions: [PowerAssertion] = []

    private var timer: Timer?

    init() {
        startMonitoring()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        sample()
    }

    func sample() {
        Task {
            let assertions = await Self.fetchAssertionsAsync()
            self.activeAssertions = assertions
            try? DatabaseService.shared.saveAssertions(assertions)
        }
    }

    /// Runs the (blocking) pmset subprocess off the main thread, then returns to the caller.
    nonisolated static func fetchAssertionsAsync() async -> [PowerAssertion] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: fetchAssertions())
            }
        }
    }

    nonisolated static func fetchAssertions() -> [PowerAssertion] {
        let process = Process()
        process.launchPath = "/usr/bin/pmset"
        process.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parse(pmsetOutput: output)
    }

    // Parses lines like:
    //   pid 1234(loginwindow): [0x0001234500000001] 00:01:31 PreventUserIdleSystemSleep named: "UserIsActive"
    nonisolated static func parse(pmsetOutput: String) -> [PowerAssertion] {
        let pattern = #"pid\s+(\d+)\(([^)]+)\).*?(Prevent\w+|BackgroundTask|NoIdleSleepAssertion)\s+named:\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        var assertions: [PowerAssertion] = []
        let now = Date()

        for line in pmsetOutput.components(separatedBy: "\n") {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                let processName = nsLine.substring(with: match.range(at: 2))
                let assertionType = nsLine.substring(with: match.range(at: 3))
                let reason = nsLine.substring(with: match.range(at: 4))
                assertions.append(PowerAssertion(
                    id: nil,
                    timestamp: now,
                    processName: processName,
                    assertionType: assertionType,
                    reasonText: reason
                ))
            }
        }

        return assertions
    }
}
