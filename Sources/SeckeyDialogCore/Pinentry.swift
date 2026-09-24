import Foundation

/// Percent-encodes a value for an Assuan `D` line.
public func assuanEncode(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "%": out += "%25"
        case "\n": out += "%0A"
        case "\r": out += "%0D"
        default:
            if scalar.value < 32 {
                out += String(format: "%%%02X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

/// Decodes `%XX` escapes as gpg-agent sends them, as UTF-8.
public func assuanDecode(_ value: String) -> String {
    let bytes = Array(value.utf8)
    var out: [UInt8] = []
    var index = 0
    while index < bytes.count {
        if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
            let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
        {
            out.append(high << 4 | low)
            index += 3
        } else {
            out.append(bytes[index])
            index += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    default: nil
    }
}

public struct PinentryState: Equatable, Sendable {
    public var title = "PIN Entry"
    public var description = "Enter passphrase"
    public var prompt = "Passphrase"
    public var error = ""
    public var okLabel = "OK"
    public var cancelLabel = "Cancel"
    public var repeatLabel: String?
    public var keyInfo = ""
    public var tty = ""
    public var ownerPid: Int32 = 0

    public init() {}

    /// What a saved PIN is filed under: `gpg:<keygrip>`, or `piv:<card serial>` when gpg-agent
    /// is asking for a smartcard PIN, or empty when the request can't be pinned to a key.
    public var keyID: String {
        var grip = keyInfo
        for prefix in ["n/", "s/"] where grip.hasPrefix(prefix) {
            grip.removeFirst(prefix.count)
        }
        if grip.hasPrefix("-") {
            let text = assuanDecode(description)
            guard let match = text.firstMatch(of: /Number:\s+([0-9A-Fa-f ]+)/) else { return "" }
            return "piv:" + match.1.replacingOccurrences(of: " ", with: "")
        }
        return grip.isEmpty ? "" : "gpg:\(grip)"
    }
}

/// A pinentry: gpg-agent writes Assuan commands to it, one per line, and reads the responses.
@MainActor
public final class PinentrySession {
    public static let cancelled = "ERR 83886179 Operation cancelled <seckey-dialog>"

    public private(set) var state = PinentryState()
    let dialogs: Dialogs
    let store: SecretStore
    let settings: Settings
    let detect: (PinentryState) -> DetectedApp?
    let log: DebugLog

    public init(
        dialogs: Dialogs, store: SecretStore, settings: Settings,
        log: DebugLog = DebugLog(enabled: false), detect: @escaping (PinentryState) -> DetectedApp?
    ) {
        self.dialogs = dialogs
        self.store = store
        self.settings = settings
        self.detect = detect
        self.log = log
    }

    public var greeting: String { "OK Pleased to meet you" }

    /// The responses to one command, and whether the session is over.
    public func handle(_ rawLine: String) -> (responses: [String], done: Bool) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        log("<<< \(line)")
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = (parts.first ?? "").uppercased()
        let argument = parts.count > 1 ? parts[1] : ""

        switch command {
        case "SETTITLE":
            if !argument.isEmpty { state.title = assuanDecode(argument) }
        case "SETDESC": state.description = argument
        case "SETPROMPT": state.prompt = assuanDecode(argument)
        case "SETERROR": state.error = argument
        case "SETOK": state.okLabel = assuanDecode(argument)
        case "SETCANCEL": state.cancelLabel = assuanDecode(argument)
        case "SETREPEAT": state.repeatLabel = argument.isEmpty ? "Repeat passphrase" : assuanDecode(argument)
        case "SETKEYINFO": state.keyInfo = argument
        case "OPTION": setOption(argument)
        case "GETINFO": return (info(argument) + ["OK"], false)
        case "GETPIN":
            let responses = getPIN()
            state.error = ""
            state.repeatLabel = nil
            return (responses, false)
        case "CONFIRM", "MESSAGE":
            let ok = dialogs.confirm(
                title: assuanDecode(state.title), message: assuanDecode(state.description),
                okLabel: state.okLabel, cancelLabel: state.cancelLabel, icon: settings.icon(for: nil))
            return ([ok ? "OK" : Self.cancelled], false)
        case "RESET": state = PinentryState()
        case "BYE": return (["OK closing connection"], true)
        default: log("ignored: \(command)")
        }
        return (["OK"], false)
    }

    private func setOption(_ argument: String) {
        let pair = argument.split(separator: "=", maxSplits: 1).map(String.init)
        let value = pair.count > 1 ? pair[1] : ""
        switch pair.first {
        case "ttyname": state.tty = value
        case "owner":
            // "owner=<pid>/<uid> <host>"
            let pid = value.split(whereSeparator: { $0 == "/" || $0 == " " }).first
            state.ownerPid = pid.flatMap { Int32($0) } ?? 0
        default: break
        }
    }

    private func info(_ what: String) -> [String] {
        switch what {
        case "flavor": ["D seckey-dialog"]
        case "version": ["D \(SeckeyDialog.version)"]
        case "ttyinfo": ["D - - -"]
        case "pid": ["D \(getpid())"]
        default: []
        }
    }

    private func getPIN() -> [String] {
        let keyID = state.keyID
        let app = detect(state)
        log("GETPIN key=\(keyID) app=\(app?.id ?? "-") repeat=\(state.repeatLabel != nil)")

        // Saved PINs are only read or written when the user opted in, for a request that can be
        // tied to both a key and a recognised app.
        let account = settings.savePINs && !keyID.isEmpty ? app.map { Account.name(key: keyID, app: $0.id) } : nil

        if let account, state.repeatLabel == nil, let saved = store.secret(for: account), !saved.isEmpty {
            log("GETPIN: using saved PIN for \(account)")
            return ["D \(assuanEncode(saved))", "OK"]
        }

        var message = assuanDecode(state.description)
        if !state.error.isEmpty { message = assuanDecode(state.error) + "\n\n" + message }
        let request = SecretRequest(
            title: assuanDecode(state.title), message: message, label: state.prompt,
            repeatLabel: state.repeatLabel, offerSave: account != nil, okLabel: state.okLabel,
            cancelLabel: state.cancelLabel, icon: settings.icon(for: app))

        guard let answer = dialogs.askSecretConfirmed(request) else { return [Self.cancelled] }
        if answer.save, let account {
            store.save(answer.secret, for: account)
            log("GETPIN: saved \(account)")
        }
        return ["D \(assuanEncode(answer.secret))", "OK"]
    }
}
