import Foundation

public protocol CommandRunning: Sendable {
    /// Runs a program and returns its standard output and exit status. Status -1 if it couldn't start.
    func run(_ path: String, _ arguments: [String]) -> (output: String, status: Int32)
}

public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ path: String, _ arguments: [String]) -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ("", -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

/// The first executable named `name` in `PATH` or the usual Homebrew locations.
public func findExecutable(
    _ name: String,
    path: String? = ProcessInfo.processInfo.environment["PATH"],
    fileManager: FileManager = .default
) -> String? {
    let directories = (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    for directory in directories where !directory.isEmpty {
        let candidate = (directory as NSString).appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Runs `body` while holding an exclusive lock on `path`, so only one dialog shows at a time
/// across processes. The lock belongs to the file descriptor, so a crash releases it.
public func withExclusiveLock<T>(at path: String, _ body: () -> T) -> T {
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return body() }
    defer {
        flock(fd, LOCK_UN)
        close(fd)
    }
    flock(fd, LOCK_EX)
    return body()
}
