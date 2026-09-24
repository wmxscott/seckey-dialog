import Foundation
import Testing

@testable import SeckeyDialogCore

@MainActor
@Suite struct PinentryTests {
    let dialogs = FakeDialogs()
    let store = FakeStore()

    func session(savePINs: Bool = false, app: DetectedApp? = ghostty) -> PinentrySession {
        PinentrySession(dialogs: dialogs, store: store, settings: Settings(savePINs: savePINs)) { _ in app }
    }

    func run(_ session: PinentrySession, _ lines: [String]) -> [String] {
        lines.flatMap { session.handle($0).responses }
    }

    // MARK: Encoding

    @Test(arguments: ["plain", "100%", "two\nlines", "cr\r", "tab\t", "ünïcödé 🔑"])
    func encodingRoundTrips(value: String) {
        #expect(assuanDecode(assuanEncode(value)) == value)
    }

    @Test func encodingEscapesControlCharacters() {
        #expect(assuanEncode("a%b\nc\r\u{1}") == "a%25b%0Ac%0D%01")
    }

    @Test func decodingHandlesUTF8AndStrayPercent() {
        #expect(assuanDecode("caf%C3%A9 100%") == "café 100%")
        #expect(assuanDecode("%zz%4") == "%zz%4")
    }

    // MARK: Protocol

    @Test func greetsAndAnswersInfo() {
        let session = session()
        #expect(session.greeting == "OK Pleased to meet you")
        #expect(run(session, ["GETINFO flavor"]) == ["D seckey-dialog", "OK"])
        #expect(run(session, ["GETINFO version"]) == ["D \(SeckeyDialog.version)", "OK"])
        #expect(run(session, ["GETINFO ttyinfo"]) == ["D - - -", "OK"])
        #expect(run(session, ["GETINFO unknown"]) == ["OK"])
    }

    @Test func settersAcknowledgeAndStore() {
        let session = session()
        let responses = run(
            session,
            [
                "SETTITLE My%20Title", "SETDESC Enter%0Athe PIN", "SETPROMPT PIN:", "SETOK Unlock",
                "SETCANCEL Stop", "SETKEYINFO n/ABCDEF", "OPTION ttyname=/dev/ttys003",
                "OPTION owner=4242/501 host.local", "SETQUALITYBAR", "NOP", "SOMETHINGNEW x",
            ])
        #expect(responses == Array(repeating: "OK", count: 11))
        #expect(session.state.title == "My Title")
        #expect(session.state.prompt == "PIN:")
        #expect(session.state.okLabel == "Unlock")
        #expect(session.state.tty == "/dev/ttys003")
        #expect(session.state.ownerPid == 4242)
        #expect(session.state.keyID == "gpg:ABCDEF")
    }

    @Test func toleratesCarriageReturns() {
        let session = session()
        #expect(run(session, ["SETPROMPT PIN:\r"]) == ["OK"])
        #expect(session.state.prompt == "PIN:")
    }

    @Test func resetRestoresDefaults() {
        let session = session()
        _ = run(session, ["SETTITLE X", "SETKEYINFO n/AB", "RESET"])
        #expect(session.state == PinentryState())
    }

    @Test func byeEndsTheSession() {
        let (responses, done) = session().handle("BYE")
        #expect(responses == ["OK closing connection"])
        #expect(done)
    }

    @Test func confirmMapsToOKOrCancelled() {
        let session = session()
        #expect(run(session, ["SETDESC Sure%3F", "CONFIRM"]) == ["OK", "OK"])
        #expect(dialogs.confirms.last?.message == "Sure?")
        dialogs.confirmResult = false
        #expect(run(session, ["MESSAGE"]) == [PinentrySession.cancelled])
    }

    // MARK: GETPIN

    @Test func getPINReturnsTheEncodedAnswer() throws {
        dialogs.answers = [SecretAnswer(secret: "12%34")]
        let responses = run(session(), ["SETDESC Please%0Aenter", "SETPROMPT PIN", "GETPIN"])
        #expect(responses.suffix(2) == ["D 12%2534", "OK"])
        let request = try #require(dialogs.secretRequests.first)
        #expect(request.message == "Please\nenter")
        #expect(request.label == "PIN")
        #expect(request.icon == .app("/Applications/Ghostty.app"))
    }

    @Test func cancellingGetPIN() {
        #expect(run(session(), ["GETPIN"]) == [PinentrySession.cancelled])
    }

    @Test func errorIsShownAboveTheDescriptionOnce() {
        dialogs.answers = [SecretAnswer(secret: "1"), SecretAnswer(secret: "2")]
        let session = session()
        _ = run(session, ["SETDESC Enter", "SETERROR Bad%20PIN", "GETPIN", "GETPIN"])
        #expect(dialogs.secretRequests.first?.message == "Bad PIN\n\nEnter")
        #expect(dialogs.secretRequests.dropFirst().first?.message == "Enter")
    }

    @Test func repeatAsksAgainUntilBothMatch() {
        dialogs.answers = [
            SecretAnswer(secret: "new", repeated: "typo"),
            SecretAnswer(secret: "new", repeated: "new"),
        ]
        let responses = run(session(), ["SETREPEAT Again", "GETPIN"])
        #expect(responses.suffix(2) == ["D new", "OK"])
        #expect(dialogs.secretRequests.count == 2)
        #expect(dialogs.secretRequests.first?.repeatLabel == "Again")
        #expect(dialogs.secretRequests.dropFirst().first?.message.contains("don't match") == true)
    }

    // MARK: Saved PINs

    @Test func savingIsOffByDefault() {
        store.secrets["gpg:AB:com.mitchellh.ghostty"] = "saved"
        dialogs.answers = [SecretAnswer(secret: "typed", save: true)]
        let responses = run(session(), ["SETKEYINFO n/AB", "GETPIN"])

        #expect(responses.suffix(2) == ["D typed", "OK"])
        #expect(store.reads.isEmpty)
        #expect(dialogs.secretRequests.first?.offerSave == false)
        #expect(store.secrets["gpg:AB:com.mitchellh.ghostty"] == "saved")
    }

    @Test func savedPINIsUsedWhenEnabled() {
        store.secrets["gpg:AB:com.mitchellh.ghostty"] = "saved"
        let responses = run(session(savePINs: true), ["SETKEYINFO n/AB", "GETPIN"])
        #expect(responses.suffix(2) == ["D saved", "OK"])
        #expect(dialogs.secretRequests.isEmpty)
    }

    @Test func savesWhenTheBoxIsTicked() {
        dialogs.answers = [SecretAnswer(secret: "1234", save: true)]
        _ = run(session(savePINs: true), ["SETKEYINFO n/AB", "GETPIN"])
        #expect(dialogs.secretRequests.first?.offerSave == true)
        #expect(store.secrets == ["gpg:AB:com.mitchellh.ghostty": "1234"])
    }

    @Test func doesNotSaveWhenTheBoxIsLeftClear() {
        dialogs.answers = [SecretAnswer(secret: "1234", save: false)]
        _ = run(session(savePINs: true), ["SETKEYINFO n/AB", "GETPIN"])
        #expect(store.secrets.isEmpty)
    }

    @Test func savedPINsAreScopedToTheApp() {
        store.secrets["gpg:AB:com.other.app"] = "other"
        dialogs.answers = [SecretAnswer(secret: "typed")]
        let responses = run(session(savePINs: true), ["SETKEYINFO n/AB", "GETPIN"])
        #expect(responses.suffix(2) == ["D typed", "OK"])
    }

    @Test func noSavingForAnUnrecognisedApp() {
        dialogs.answers = [SecretAnswer(secret: "typed", save: true)]
        _ = run(session(savePINs: true, app: nil), ["SETKEYINFO n/AB", "GETPIN"])
        #expect(dialogs.secretRequests.first?.offerSave == false)
        #expect(store.reads.isEmpty)
        #expect(store.secrets.isEmpty)
    }

    @Test func noSavingWithoutAKey() {
        dialogs.answers = [SecretAnswer(secret: "typed", save: true)]
        _ = run(session(savePINs: true), ["GETPIN"])
        #expect(dialogs.secretRequests.first?.offerSave == false)
        #expect(store.secrets.isEmpty)
    }

    @Test func aNewPassphraseIsNeverFilledFromTheKeychain() {
        store.secrets["gpg:AB:com.mitchellh.ghostty"] = "old"
        dialogs.answers = [SecretAnswer(secret: "new", repeated: "new")]
        let responses = run(session(savePINs: true), ["SETKEYINFO n/AB", "SETREPEAT", "GETPIN"])
        #expect(responses.suffix(2) == ["D new", "OK"])
    }

    // MARK: Key IDs

    @Test func smartcardPINsAreFiledByCardSerial() {
        var state = PinentryState()
        state.keyInfo = "--clear"
        state.description = "Please%20unlock%20the%20card%0ANumber:%2012%20345%20678"
        #expect(state.keyID == "piv:12345678")
    }

    @Test func keyIDs() {
        var state = PinentryState()
        #expect(state.keyID == "")
        state.keyInfo = "s/0123ABCD"
        #expect(state.keyID == "gpg:0123ABCD")
        state.keyInfo = "--clear"
        state.description = "no serial here"
        #expect(state.keyID == "")
    }
}
