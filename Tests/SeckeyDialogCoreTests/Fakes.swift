import Foundation

@testable import SeckeyDialogCore

@MainActor
final class FakeDialogs: Dialogs {
    var answers: [SecretAnswer?] = []
    var confirmResult = true
    var touchResult = true
    private(set) var secretRequests: [SecretRequest] = []
    private(set) var confirms: [(title: String, message: String)] = []
    private(set) var touches: [(message: String, icon: DialogIcon)] = []

    func askSecret(_ request: SecretRequest) -> SecretAnswer? {
        secretRequests.append(request)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func confirm(title: String, message: String, okLabel: String, cancelLabel: String, icon: DialogIcon) -> Bool {
        confirms.append((title, message))
        return confirmResult
    }

    func touch(title: String, message: String, icon: DialogIcon) -> Bool {
        touches.append((message, icon))
        return touchResult
    }
}

final class FakeStore: SecretStore {
    var secrets: [String: String] = [:]
    private(set) var reads: [String] = []

    func secret(for account: String) -> String? {
        reads.append(account)
        return secrets[account]
    }

    func save(_ secret: String, for account: String) -> Bool {
        secrets[account] = secret
        return true
    }

    func delete(_ account: String) -> Bool { secrets.removeValue(forKey: account) != nil }
    func accounts() -> [String] { secrets.keys.sorted() }
}

/// A process tree: pid -> (executable path, parent pid).
struct FakeProcesses: ProcessInspecting {
    var tree: [Int32: (command: String, parent: Int32)] = [:]
    var ttys: [String: [Int32]] = [:]
    var named: [String: [Int32]] = [:]

    func command(of pid: Int32) -> String? { tree[pid]?.command }
    func parent(of pid: Int32) -> Int32? { tree[pid]?.parent }
    func processes(onTTY tty: String) -> [Int32] { ttys[tty] ?? [] }
    func processes(named name: String) -> [Int32] { named[name] ?? [] }
}

struct FakeRunner: CommandRunning {
    var outputs: [String: (output: String, status: Int32)] = [:]

    func run(_ path: String, _ arguments: [String]) -> (output: String, status: Int32) {
        outputs[([path] + arguments).joined(separator: " ")] ?? ("", 1)
    }
}

let ghostty = DetectedApp(id: "com.mitchellh.ghostty", path: "/Applications/Ghostty.app")
