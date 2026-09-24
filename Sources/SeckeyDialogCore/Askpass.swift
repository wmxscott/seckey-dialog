import Foundation

/// What ssh wants, from `SSH_ASKPASS_PROMPT`.
public enum AskpassKind: Equatable, Sendable {
    /// `none`: a notice while ssh waits for the security key to be touched.
    case touch
    /// `confirm`: a yes/no question.
    case confirm
    /// Unset: a PIN or passphrase.
    case secret

    public init(environment: [String: String]) {
        switch environment["SSH_ASKPASS_PROMPT"] {
        case "none": self = .touch
        case "confirm": self = .confirm
        default: self = .secret
        }
    }
}

public enum AskpassResult: Equatable, Sendable {
    /// Print this to standard output and exit 0.
    case answer(String)
    case accepted
    case refused
}

@MainActor
public struct AskpassHandler {
    let dialogs: Dialogs
    let store: SecretStore
    let settings: Settings
    let app: DetectedApp?
    let keyName: (String) -> String?
    let tokenSerial: () -> String?
    let log: DebugLog

    public init(
        dialogs: Dialogs, store: SecretStore, settings: Settings, app: DetectedApp?,
        log: DebugLog = DebugLog(enabled: false),
        keyName: @escaping (String) -> String? = { _ in nil },
        tokenSerial: @escaping () -> String? = { nil }
    ) {
        self.dialogs = dialogs
        self.store = store
        self.settings = settings
        self.app = app
        self.keyName = keyName
        self.tokenSerial = tokenSerial
        self.log = log
    }

    public func handle(message: String, kind: AskpassKind) -> AskpassResult {
        log("askpass: kind=\(kind) app=\(app?.id ?? "-") message=\(message)")
        let icon = settings.icon(for: app)
        switch kind {
        case .touch:
            return dialogs.touch(title: "SSH Authentication", message: touchMessage(message), icon: icon)
                ? .accepted : .refused
        case .confirm:
            let text = message.isEmpty ? "Confirm SSH operation?" : message
            return dialogs.confirm(
                title: "SSH Confirmation", message: text, okLabel: "OK", cancelLabel: "Cancel", icon: icon)
                ? .accepted : .refused
        case .secret:
            return secret(message, icon: icon)
        }
    }

    /// "Confirm user presence for key ED25519-SK SHA256:…" becomes the key's name and the app.
    func touchMessage(_ message: String) -> String {
        var lines: [String] = []
        if let match = message.firstMatch(of: /Confirm user presence for key \S+ (SHA256:\S+)/) {
            let fingerprint = String(match.1)
            lines.append("Key: \(keyName(fingerprint) ?? fingerprint)")
        }
        if let app { lines.append("Requested by: \(app.id)") }
        return (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n") + "Touch your security key…"
    }

    private func secret(_ message: String, icon: DialogIcon) -> AskpassResult {
        // A security key PIN can be saved; a key file's passphrase never is.
        let isPIN = message.contains("PIN")
        let account: String? =
            if isPIN && settings.savePINs, let app {
                Account.name(key: tokenSerial().map { "fido2:\($0)" } ?? "fido2", app: app.id)
            } else {
                nil
            }

        if let account, let saved = store.secret(for: account), !saved.isEmpty {
            log("askpass: using saved PIN for \(account)")
            return .answer(saved)
        }

        let request = SecretRequest(
            title: "SSH Authentication",
            message: message.isEmpty ? "Enter the PIN for your security key" : message,
            label: isPIN ? "PIN" : "Passphrase", offerSave: account != nil, icon: icon)
        guard let answer = dialogs.askSecret(request) else { return .refused }
        if answer.save, let account {
            store.save(answer.secret, for: account)
            log("askpass: saved \(account)")
        }
        return .answer(answer.secret)
    }
}

/// How the program was started. Neither gpg-agent nor ssh passes flags, so the mode comes from
/// the arguments themselves.
public enum Mode: Equatable, Sendable {
    /// No arguments: gpg-agent is about to speak Assuan on standard input.
    case pinentry
    /// A prompt as the only argument: ssh wants something.
    case askpass(String)
    /// One of the management commands.
    case command(String, [String])

    public static let commands: Set<String> = [
        "list", "remove", "test", "settings", "test-detect", "test-pin", "test-touch", "test-confirm",
        "--version", "-V", "help", "--help", "-h",
    ]

    public init(arguments: [String]) {
        guard let first = arguments.first, !first.isEmpty else {
            self = .pinentry
            return
        }
        self = Self.commands.contains(first) ? .command(first, Array(arguments.dropFirst())) : .askpass(first)
    }
}
