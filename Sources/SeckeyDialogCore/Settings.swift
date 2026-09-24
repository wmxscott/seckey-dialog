import Foundation

public enum SeckeyDialog {
    public static let version = "1.0.0"
    /// The `defaults` domain settings are read from.
    public static let domain = "io.github.wmxscott.seckey-dialog"
    /// The keychain service saved PINs are stored under.
    public static let keychainService = "seckey-dialog"
}

public struct Settings: Equatable, Sendable {
    public enum Key {
        public static let savePINs = "SavePINs"
        public static let allowedApps = "AllowedApps"
        public static let iconPath = "IconPath"
        public static let debug = "Debug"
    }

    /// Apps whose requests are recognised: named in the dialog, and able to use saved PINs.
    /// An entry ending in `.app` matches any process inside that bundle; any other entry
    /// matches a process by its executable name.
    public static let defaultAllowedApps = [
        "Terminal.app", "iTerm.app", "Ghostty.app", "WezTerm.app", "kitty.app", "Alacritty.app",
        "Warp.app", "Zed.app", "Visual Studio Code.app", "Cursor.app",
    ]

    /// Off by default. See SECURITY.md before turning it on.
    public var savePINs: Bool
    public var allowedApps: [String]
    public var iconPath: String?
    public var debug: Bool

    public init(
        savePINs: Bool = false,
        allowedApps: [String] = Settings.defaultAllowedApps,
        iconPath: String? = nil,
        debug: Bool = false
    ) {
        self.savePINs = savePINs
        self.allowedApps = allowedApps
        self.iconPath = iconPath
        self.debug = debug
    }

    public static func load(from defaults: UserDefaults, environment: [String: String]) -> Settings {
        var settings = Settings()
        settings.savePINs = defaults.bool(forKey: Key.savePINs)
        if let apps = defaults.stringArray(forKey: Key.allowedApps) {
            settings.allowedApps = apps.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let icon = defaults.string(forKey: Key.iconPath), !icon.isEmpty {
            settings.iconPath = (icon as NSString).expandingTildeInPath
        }
        settings.debug = defaults.bool(forKey: Key.debug) || environment["SECKEY_DIALOG_DEBUG"] == "1"
        return settings
    }
}

/// Appends to `$TMPDIR/seckey-dialog.log` when debugging is on. Never given a secret.
public struct DebugLog: Sendable {
    public let enabled: Bool
    public let path: String

    public init(enabled: Bool, path: String = NSTemporaryDirectory() + "seckey-dialog.log") {
        self.enabled = enabled
        self.path = path
    }

    public func callAsFunction(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Int(Date().timeIntervalSince1970)) [\(getpid())] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
