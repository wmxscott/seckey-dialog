import Foundation
import Testing

@testable import SeckeyDialogCore

@Suite struct AppDetectionTests {
    let ghosttyCommand = "/Applications/Ghostty.app/Contents/MacOS/ghostty"

    func detector(_ processes: FakeProcesses, apps: [String] = Settings.defaultAllowedApps) -> AppDetector {
        AppDetector(processes: processes, allowedApps: apps) { path in
            path == "/Applications/Ghostty.app" ? "com.mitchellh.ghostty" : nil
        }
    }

    @Test func matchesAppBundlesAnywhereInThePath() {
        let matcher = AppMatcher(["Visual Studio Code.app", "tmux"])
        let helper =
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        #expect(matcher.match(helper)?.bundlePath == "/Applications/Visual Studio Code.app")
        #expect(matcher.match("/Users/someone/.local/bin/tmux")?.entry == "tmux")
        #expect(matcher.match("tmux")?.bundlePath == nil)
    }

    @Test func matchesWholeNamesOnly() {
        let matcher = AppMatcher(["git", "Zed.app"])
        #expect(matcher.match("/Applications/Logi Options+.app/Contents/MacOS/logioptionsplus_agent") == nil)
        #expect(matcher.match("/usr/bin/gitk") == nil)
        #expect(matcher.match("/Applications/Zedx.app/Contents/MacOS/zed") == nil)
        #expect(matcher.match("/usr/bin/GIT") != nil)
    }

    @Test func walksUpToTheApp() {
        let processes = FakeProcesses(tree: [
            100: ("/usr/bin/ssh", 90), 90: ("/bin/zsh", 80), 80: (ghosttyCommand, 1),
        ])
        #expect(
            detector(processes).walk(from: 100)
                == DetectedApp(id: "com.mitchellh.ghostty", path: "/Applications/Ghostty.app"))
    }

    @Test func fallsBackToTheBundleName() {
        let processes = FakeProcesses(tree: [5: ("/Applications/Zed.app/Contents/MacOS/zed", 1)])
        #expect(detector(processes).walk(from: 5) == DetectedApp(id: "Zed", path: "/Applications/Zed.app"))
    }

    @Test func plainExecutablesAreNamedByTheirEntry() {
        let processes = FakeProcesses(tree: [5: ("/Users/someone/.local/bin/tmux", 1)])
        #expect(detector(processes, apps: ["tmux"]).walk(from: 5) == DetectedApp(id: "tmux", path: nil))
    }

    @Test func givesUpAtInitOrTheDepthLimit() {
        var tree: [Int32: (command: String, parent: Int32)] = [:]
        for pid in Int32(2)...Int32(40) { tree[pid] = ("/bin/sh", pid - 1) }
        tree[2] = (ghosttyCommand, 1)
        #expect(detector(FakeProcesses(tree: tree)).walk(from: 40) == nil)
        #expect(detector(FakeProcesses(tree: tree)).walk(from: 15) != nil)
        #expect(detector(FakeProcesses()).walk(from: 1) == nil)
    }

    @Test func askpassFallsBackToWaitingSshProcesses() {
        let processes = FakeProcesses(
            tree: [10: ("/usr/bin/ssh-agent", 1), 20: ("/usr/bin/ssh", 30), 30: (ghosttyCommand, 1)],
            named: ["ssh": [20]])
        #expect(detector(processes).forAskpass(selfPid: 10)?.id == "com.mitchellh.ghostty")
    }

    @Test func pinentryPrefersTheTerminal() {
        let processes = FakeProcesses(
            tree: [
                10: ("/opt/homebrew/bin/gpg-agent", 1), 20: ("/bin/zsh", 30), 30: (ghosttyCommand, 1),
                40: ("/Applications/Zed.app/Contents/MacOS/zed", 1),
            ],
            ttys: ["/dev/ttys001": [20]])
        let detector = detector(processes)
        #expect(detector.forPinentry(tty: "/dev/ttys001", ownerPid: 40, selfPid: 10)?.id == "com.mitchellh.ghostty")
        #expect(detector.forPinentry(tty: "", ownerPid: 40, selfPid: 10)?.id == "Zed")
        #expect(detector.forPinentry(tty: "", ownerPid: 0, selfPid: 10) == nil)
    }
}

@Suite struct KeyNameTests {
    @Test func commentFromKeygenOutput() {
        let output = "256 SHA256:abc ssh:Backup Key (ED25519-SK)\n"
        #expect(KeyNames.comment(inKeygenOutput: output, fingerprint: "SHA256:abc") == "Backup Key")
        #expect(KeyNames.comment(inKeygenOutput: output, fingerprint: "SHA256:xyz") == nil)
        #expect(KeyNames.comment(inKeygenOutput: "256 SHA256:abc  (ED25519)", fingerprint: "SHA256:abc") == nil)
    }

    @Test func searchesPublicKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.pub", "b.pub", "id_ed25519"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }
        let runner = FakeRunner(outputs: [
            "/usr/bin/ssh-keygen -lf \(directory.path)/a.pub": ("256 SHA256:aaa ssh:Spare Key (ED25519-SK)", 0),
            "/usr/bin/ssh-keygen -lf \(directory.path)/b.pub": ("256 SHA256:bbb laptop (ED25519)", 0),
        ])
        let names = KeyNames(directory: directory.path, runner: runner)
        #expect(names.name(for: "SHA256:bbb") == "laptop")
        #expect(names.name(for: "SHA256:aaa") == "Spare Key")
        #expect(names.name(for: "SHA256:zzz") == nil)
        #expect(names.name(for: "") == nil)
    }
}

@Suite struct TokenSerialTests {
    @Test func firstSerialFromYkman() {
        let runner = FakeRunner(outputs: ["/bin/ykman list --serials": ("12345678\n87654321\n", 0)])
        #expect(TokenSerial(ykman: "/bin/ykman", runner: runner).current() == "12345678")
    }

    @Test func nothingWithoutYkmanOrAKey() {
        #expect(TokenSerial(ykman: nil, runner: FakeRunner()).current() == nil)
        let runner = FakeRunner(outputs: ["/bin/ykman list --serials": ("", 0)])
        #expect(TokenSerial(ykman: "/bin/ykman", runner: runner).current() == nil)
        #expect(TokenSerial(ykman: "/bin/ykman", runner: FakeRunner()).current() == nil)
    }
}

@Suite struct SettingsTests {
    final class Scratch {
        let name = "seckey-dialog.tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    @Test func defaultsAreSafe() {
        let scratch = Scratch()
        let settings = Settings.load(from: scratch.defaults, environment: [:])
        #expect(settings == Settings())
        #expect(settings.savePINs == false)
        #expect(settings.allowedApps.contains("Terminal.app"))
    }

    @Test func readsEveryKey() {
        let scratch = Scratch()
        scratch.defaults.set(true, forKey: Settings.Key.savePINs)
        scratch.defaults.set(["Ghostty.app", " tmux ", ""], forKey: Settings.Key.allowedApps)
        scratch.defaults.set("~/key.png", forKey: Settings.Key.iconPath)
        scratch.defaults.set(true, forKey: Settings.Key.debug)
        let settings = Settings.load(from: scratch.defaults, environment: [:])
        #expect(settings.savePINs)
        #expect(settings.allowedApps == ["Ghostty.app", "tmux"])
        #expect(settings.iconPath == NSHomeDirectory() + "/key.png")
        #expect(settings.debug)
    }

    @Test func debugFromTheEnvironment() {
        let scratch = Scratch()
        #expect(Settings.load(from: scratch.defaults, environment: ["SECKEY_DIALOG_DEBUG": "1"]).debug)
    }

    @Test func debugLogIsPrivate() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        DebugLog(enabled: false, path: path)("hidden")
        #expect(!FileManager.default.fileExists(atPath: path))
        let log = DebugLog(enabled: true, path: path)
        log("one")
        log("two")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("one\n") && text.contains("two\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

@Suite struct CommandTests {
    @Test func findsExecutablesOnThePath() {
        #expect(findExecutable("ls", path: "/nonexistent:/bin") == "/bin/ls")
        #expect(findExecutable("no-such-program-here", path: "/bin") == nil)
    }

    @Test func runnerCapturesOutputAndStatus() {
        let runner = CommandRunner()
        #expect(runner.run("/bin/echo", ["hi"]) == ("hi\n", 0) as (String, Int32))
        #expect(runner.run("/usr/bin/false", []).status == 1)
        #expect(runner.run("/no/such/program", []).status == -1)
    }

    @Test func lockRunsTheBody() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/lock").path
        #expect(withExclusiveLock(at: path) { 42 } == 42)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Suite(.serialized) struct KeychainTests {
    /// Exercises the real login keychain under a throwaway service name.
    @Test func roundTrip() throws {
        let store = KeychainStore(service: "seckey-dialog.tests.\(UUID().uuidString)")
        guard store.save("s3cret", for: "a:1") else {
            // CI runners may have no unlocked keychain; everywhere else this must work.
            #expect(ProcessInfo.processInfo.environment["CI"] != nil, "couldn't write to the login keychain")
            return
        }
        defer {
            for account in store.accounts() { store.delete(account) }
        }
        #expect(store.secret(for: "a:1") == "s3cret")
        #expect(store.save("changed", for: "a:1"))
        #expect(store.secret(for: "a:1") == "changed")
        #expect(store.save("x", for: "b:2"))
        #expect(store.accounts() == ["a:1", "b:2"])
        #expect(store.delete("a:1"))
        #expect(!store.delete("a:1"))
        #expect(store.secret(for: "a:1") == nil)
    }
}
