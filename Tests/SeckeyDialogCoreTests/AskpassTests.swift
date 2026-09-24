import Foundation
import Testing

@testable import SeckeyDialogCore

@MainActor
@Suite struct AskpassTests {
    let dialogs = FakeDialogs()
    let store = FakeStore()

    func handler(
        savePINs: Bool = false, app: DetectedApp? = ghostty, serial: String? = "12345678",
        iconPath: String? = nil
    ) -> AskpassHandler {
        AskpassHandler(
            dialogs: dialogs, store: store, settings: Settings(savePINs: savePINs, iconPath: iconPath), app: app,
            keyName: { $0 == "SHA256:abc" ? "Work Key" : nil }, tokenSerial: { serial })
    }

    @Test(arguments: [
        ([:], AskpassKind.secret), (["SSH_ASKPASS_PROMPT": "none"], .touch),
        (["SSH_ASKPASS_PROMPT": "confirm"], .confirm), (["SSH_ASKPASS_PROMPT": "other"], .secret),
    ])
    func kindComesFromTheEnvironment(environment: [String: String], kind: AskpassKind) {
        #expect(AskpassKind(environment: environment) == kind)
    }

    @Test func touchNamesTheKeyAndTheApp() {
        let result = handler().handle(
            message: "Confirm user presence for key ED25519-SK SHA256:abc", kind: .touch)
        #expect(result == .accepted)
        #expect(
            dialogs.touches.first?.message
                == "Key: Work Key\nRequested by: com.mitchellh.ghostty\n\nTouch your security key…")
    }

    @Test func touchFallsBackToTheFingerprint() {
        _ = handler(app: nil).handle(message: "Confirm user presence for key ED25519-SK SHA256:zzz", kind: .touch)
        #expect(dialogs.touches.first?.message == "Key: SHA256:zzz\n\nTouch your security key…")
    }

    @Test func cancelledTouchIsRefused() {
        dialogs.touchResult = false
        #expect(handler().handle(message: "", kind: .touch) == .refused)
        #expect(dialogs.touches.first?.message == "Requested by: com.mitchellh.ghostty\n\nTouch your security key…")
    }

    @Test func confirm() {
        #expect(handler().handle(message: "Allow?", kind: .confirm) == .accepted)
        #expect(dialogs.confirms.first?.message == "Allow?")
        dialogs.confirmResult = false
        #expect(handler().handle(message: "", kind: .confirm) == .refused)
        #expect(dialogs.confirms.dropFirst().first?.message == "Confirm SSH operation?")
    }

    @Test func pinIsReturned() {
        dialogs.answers = [SecretAnswer(secret: "123456")]
        let result = handler().handle(message: "Enter PIN for ED25519-SK key /k: ", kind: .secret)
        #expect(result == .answer("123456"))
        #expect(dialogs.secretRequests.first?.label == "PIN")
    }

    @Test func cancelledPINIsRefused() {
        #expect(handler().handle(message: "Enter PIN", kind: .secret) == .refused)
    }

    @Test func savingIsOffByDefault() {
        store.secrets["fido2:12345678:com.mitchellh.ghostty"] = "saved"
        dialogs.answers = [SecretAnswer(secret: "typed", save: true)]
        #expect(handler().handle(message: "Enter PIN", kind: .secret) == .answer("typed"))
        #expect(store.reads.isEmpty)
        #expect(dialogs.secretRequests.first?.offerSave == false)
        #expect(store.secrets.count == 1)
    }

    @Test func savedPINIsPerTokenAndApp() {
        store.secrets["fido2:12345678:com.mitchellh.ghostty"] = "saved"
        #expect(handler(savePINs: true).handle(message: "Enter PIN", kind: .secret) == .answer("saved"))
        #expect(dialogs.secretRequests.isEmpty)

        dialogs.answers = [SecretAnswer(secret: "typed")]
        #expect(handler(savePINs: true, serial: "999").handle(message: "Enter PIN", kind: .secret) == .answer("typed"))
    }

    @Test func savesUnderTheTokenSerial() {
        dialogs.answers = [SecretAnswer(secret: "123456", save: true)]
        _ = handler(savePINs: true).handle(message: "Enter PIN", kind: .secret)
        #expect(store.secrets == ["fido2:12345678:com.mitchellh.ghostty": "123456"])
    }

    @Test func withoutASerialThePINIsSavedForAnyToken() {
        dialogs.answers = [SecretAnswer(secret: "123456", save: true)]
        _ = handler(savePINs: true, serial: nil).handle(message: "Enter PIN", kind: .secret)
        #expect(store.secrets == ["fido2:com.mitchellh.ghostty": "123456"])
    }

    @Test func passphrasesAreNeverSaved() {
        dialogs.answers = [SecretAnswer(secret: "hunter2", save: true)]
        let result = handler(savePINs: true).handle(
            message: "Enter passphrase for key '/Users/someone/.ssh/id_ed25519': ", kind: .secret)
        #expect(result == .answer("hunter2"))
        #expect(dialogs.secretRequests.first?.label == "Passphrase")
        #expect(dialogs.secretRequests.first?.offerSave == false)
        #expect(store.secrets.isEmpty)
        #expect(store.reads.isEmpty)
    }

    @Test func noSavingForAnUnrecognisedApp() {
        dialogs.answers = [SecretAnswer(secret: "1", save: true)]
        _ = handler(savePINs: true, app: nil).handle(message: "Enter PIN", kind: .secret)
        #expect(dialogs.secretRequests.first?.offerSave == false)
        #expect(store.secrets.isEmpty)
    }

    @Test func icons() {
        _ = handler(app: nil, iconPath: "/tmp/key.png").handle(message: "", kind: .touch)
        _ = handler(app: nil).handle(message: "", kind: .touch)
        _ = handler().handle(message: "", kind: .touch)
        #expect(dialogs.touches.map(\.icon) == [.file("/tmp/key.png"), .standard, .app("/Applications/Ghostty.app")])
    }

    @Test(arguments: [
        ([], Mode.pinentry), ([""], .pinentry), (["Enter PIN"], .askpass("Enter PIN")),
        (["list"], .command("list", [])), (["remove", "x"], .command("remove", ["x"])),
        (["--version"], .command("--version", [])),
    ])
    func modeComesFromTheArguments(arguments: [String], mode: Mode) {
        #expect(Mode(arguments: arguments) == mode)
    }
}
