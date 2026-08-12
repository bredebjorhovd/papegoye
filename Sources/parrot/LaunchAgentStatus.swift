import Foundation

/// What launchd currently thinks of parrot's LaunchAgent.
///
/// The interesting state is "installed, loaded, and not running": on its own
/// that is invisible — the menu bar icon is simply absent — and the two ways to
/// get there need different sentences from `doctor` (gh#35).
struct LaunchAgentState: Equatable {
    /// nil when the job is loaded but not currently running.
    var pid: Int?
    /// Exit status of the last run, as launchd reports it. nil when it has
    /// never run in this boot.
    var lastExitStatus: Int?

    var isRunning: Bool { pid != nil }
}

enum LaunchAgentInspector {
    static let label = Install.label

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static func isInstalled(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    /// `launchctl list` prints one tab-separated "PID  Status  Label" row per
    /// job, with "-" wherever a number doesn't apply. Returns nil when the label
    /// isn't listed at all, which means the plist exists but was never loaded.
    static func parse(list output: String, label: String = label) -> LaunchAgentState? {
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, columns[2] == label else { continue }
            return LaunchAgentState(
                pid: Int(columns[0]),
                lastExitStatus: Int(columns[1])
            )
        }
        return nil
    }

    static func state() -> LaunchAgentState? {
        guard let output = runLaunchctl(["list"]) else { return nil }
        return parse(list: output)
    }

    private static func runLaunchctl(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
