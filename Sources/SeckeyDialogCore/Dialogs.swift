import Foundation

public enum DialogIcon: Equatable, Sendable {
    /// The icon of an app bundle.
    case app(String)
    /// An image file.
    case file(String)
    /// The built-in key icon.
    case standard
}

public struct SecretRequest: Equatable, Sendable {
    public var title: String
    public var message: String
    public var label: String
    /// Ask for the secret twice, labelling the second field with this.
    public var repeatLabel: String?
    /// Show a "Save in keychain" checkbox.
    public var offerSave: Bool
    public var okLabel: String
    public var cancelLabel: String
    public var icon: DialogIcon

    public init(
        title: String, message: String, label: String, repeatLabel: String? = nil, offerSave: Bool = false,
        okLabel: String = "OK", cancelLabel: String = "Cancel", icon: DialogIcon = .standard
    ) {
        self.title = title
        self.message = message
        self.label = label
        self.repeatLabel = repeatLabel
        self.offerSave = offerSave
        self.okLabel = okLabel
        self.cancelLabel = cancelLabel
        self.icon = icon
    }
}

public struct SecretAnswer: Equatable, Sendable {
    public var secret: String
    public var repeated: String?
    public var save: Bool

    public init(secret: String, repeated: String? = nil, save: Bool = false) {
        self.secret = secret
        self.repeated = repeated
        self.save = save
    }
}

@MainActor
public protocol Dialogs {
    /// Nil when cancelled.
    func askSecret(_ request: SecretRequest) -> SecretAnswer?
    func confirm(title: String, message: String, okLabel: String, cancelLabel: String, icon: DialogIcon) -> Bool
    /// Shown while ssh waits for a touch. Dismissed by SIGTERM (true) or Cancel (false).
    func touch(title: String, message: String, icon: DialogIcon) -> Bool
}

extension Dialogs {
    /// Asks again until both fields match when the request has a repeat field.
    public func askSecretConfirmed(_ request: SecretRequest) -> SecretAnswer? {
        var request = request
        while let answer = askSecret(request) {
            if request.repeatLabel == nil || answer.repeated == answer.secret {
                return answer
            }
            request.message = "The two entries don't match. Please try again."
        }
        return nil
    }
}

extension Settings {
    /// The icon for a request from `app`: the app's own, else the configured one, else a key.
    public func icon(for app: DetectedApp?) -> DialogIcon {
        if let path = app?.path { return .app(path) }
        if let iconPath { return .file(iconPath) }
        return .standard
    }
}
