import Foundation
import Security

public protocol SecretStore {
    func secret(for account: String) -> String?
    @discardableResult func save(_ secret: String, for account: String) -> Bool
    @discardableResult func delete(_ account: String) -> Bool
    func accounts() -> [String]
}

/// Keychain account names: `<kind>:<id>:<app>`, e.g. `gpg:<keygrip>:com.mitchellh.ghostty`.
/// Scoping by app means a PIN saved while using one app is never replayed for another.
public enum Account {
    public static func name(key: String, app: String) -> String { "\(key):\(app)" }
}

/// Generic passwords in the login keychain under one service.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = SeckeyDialog.keychainService) {
        self.service = service
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func secret(for account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ secret: String, for account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary) == errSecSuccess
    }

    public func accounts() -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// Names ssh keys in prompts by the comment in `~/.ssh/*.pub`, instead of a bare fingerprint.
public struct KeyNames: Sendable {
    let directory: String
    let runner: CommandRunning

    public init(directory: String = NSHomeDirectory() + "/.ssh", runner: CommandRunning = CommandRunner()) {
        self.directory = directory
        self.runner = runner
    }

    public func name(for fingerprint: String) -> String? {
        guard !fingerprint.isEmpty,
            let files = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return nil }
        for file in files.sorted() where file.hasSuffix(".pub") {
            let output = runner.run("/usr/bin/ssh-keygen", ["-lf", "\(directory)/\(file)"]).output
            if let comment = Self.comment(inKeygenOutput: output, fingerprint: fingerprint) {
                return comment
            }
        }
        return nil
    }

    /// The comment from `ssh-keygen -lf` output (`256 SHA256:… comment (TYPE)`), without the
    /// `ssh:` prefix security keys use.
    public static func comment(inKeygenOutput output: String, fingerprint: String) -> String? {
        guard let range = output.range(of: "\(fingerprint) ") else { return nil }
        var comment = String(output[range.upperBound...])
        if let type = comment.range(of: " (", options: .backwards) {
            comment = String(comment[..<type.lowerBound])
        }
        comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if comment.hasPrefix("ssh:") { comment.removeFirst(4) }
        return comment.isEmpty ? nil : comment
    }
}

/// The serial of the connected YubiKey, from `ykman` if it's installed. FIDO2 PINs are saved
/// per token, because two keys can have different PINs.
public struct TokenSerial: Sendable {
    let ykman: String?
    let runner: CommandRunning

    public init(ykman: String? = findExecutable("ykman"), runner: CommandRunning = CommandRunner()) {
        self.ykman = ykman
        self.runner = runner
    }

    public func current() -> String? {
        guard let ykman else { return nil }
        let result = runner.run(ykman, ["list", "--serials"])
        guard result.status == 0 else { return nil }
        let serial = result.output.split(separator: "\n").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return serial?.isEmpty == false ? serial : nil
    }
}
