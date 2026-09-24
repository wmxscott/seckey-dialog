import Foundation

/// The app a request came from, found by walking up the process tree.
public struct DetectedApp: Equatable, Sendable {
    /// Bundle identifier for an app bundle, otherwise the executable name.
    public let id: String
    /// Path to the `.app` bundle, if the match was inside one.
    public let path: String?

    public init(id: String, path: String?) {
        self.id = id
        self.path = path
    }
}

public protocol ProcessInspecting: Sendable {
    /// The full executable path of a process.
    func command(of pid: Int32) -> String?
    func parent(of pid: Int32) -> Int32?
    func processes(onTTY tty: String) -> [Int32]
    /// Processes of the current user whose executable name is exactly `name`.
    func processes(named name: String) -> [Int32]
}

public struct SystemProcesses: ProcessInspecting {
    let runner: CommandRunning

    public init(runner: CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    private func field(_ pid: Int32, _ name: String) -> String? {
        let value = runner.run("/bin/ps", ["-p", "\(pid)", "-o", "\(name)="]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func command(of pid: Int32) -> String? { field(pid, "comm") }
    public func parent(of pid: Int32) -> Int32? { field(pid, "ppid").flatMap { Int32($0) } }

    public func processes(onTTY tty: String) -> [Int32] {
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        return pids(runner.run("/bin/ps", ["-t", short, "-o", "pid="]).output)
    }

    public func processes(named name: String) -> [Int32] {
        pids(runner.run("/usr/bin/pgrep", ["-u", "\(getuid())", "-x", name]).output)
    }

    private func pids(_ output: String) -> [Int32] {
        output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }
}

public struct AppMatcher: Sendable {
    public let entries: [String]

    public init(_ entries: [String]) {
        self.entries = entries
    }

    /// The allowed app bundle containing `command`, or the allowed executable name it matches.
    public func match(_ command: String) -> (entry: String, bundlePath: String?)? {
        let components = command.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let executable = components.last ?? command
        for entry in entries {
            if entry.lowercased().hasSuffix(".app") {
                guard let index = components.firstIndex(where: { $0.caseInsensitiveCompare(entry) == .orderedSame })
                else { continue }
                return (entry, components[...index].joined(separator: "/"))
            }
            if executable.caseInsensitiveCompare(entry) == .orderedSame {
                return (entry, nil)
            }
        }
        return nil
    }
}

public struct AppDetector: Sendable {
    let processes: ProcessInspecting
    let matcher: AppMatcher
    let bundleIdentifier: @Sendable (String) -> String?
    let log: DebugLog

    public static let maxDepth = 20

    public init(
        processes: ProcessInspecting,
        allowedApps: [String],
        log: DebugLog = DebugLog(enabled: false),
        bundleIdentifier: @escaping @Sendable (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }
    ) {
        self.processes = processes
        self.matcher = AppMatcher(allowedApps)
        self.bundleIdentifier = bundleIdentifier
        self.log = log
    }

    /// The first allowed app among `pid` and its ancestors.
    public func walk(from pid: Int32) -> DetectedApp? {
        var current = pid
        for _ in 0..<Self.maxDepth where current > 1 {
            guard let command = processes.command(of: current) else { return nil }
            log("  pid=\(current) comm=\(command)")
            if let (entry, bundlePath) = matcher.match(command) {
                if let bundlePath {
                    let name = (bundlePath as NSString).lastPathComponent
                    let fallback = String(name.dropLast(4))
                    return DetectedApp(id: bundleIdentifier(bundlePath) ?? fallback, path: bundlePath)
                }
                return DetectedApp(id: entry, path: nil)
            }
            guard let parent = processes.parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    /// ssh-agent runs askpass, so its own ancestry is usually the agent. Fall back to the
    /// ssh and git processes that are waiting on it.
    public func forAskpass(selfPid: Int32 = getpid()) -> DetectedApp? {
        if let app = walk(from: selfPid) { return app }
        for pid in processes.processes(named: "ssh") + processes.processes(named: "git") where pid != selfPid {
            if let app = walk(from: pid) { return app }
        }
        return nil
    }

    /// gpg-agent tells pinentry the terminal and the process that asked.
    public func forPinentry(tty: String, ownerPid: Int32, selfPid: Int32 = getpid()) -> DetectedApp? {
        if !tty.isEmpty {
            for pid in processes.processes(onTTY: tty) {
                if let app = walk(from: pid) { return app }
            }
        }
        if ownerPid > 0, let app = walk(from: ownerPid) { return app }
        return walk(from: selfPid)
    }
}
