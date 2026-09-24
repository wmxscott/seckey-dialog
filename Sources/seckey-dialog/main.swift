import Foundation
import SeckeyDialogCore

let environment = ProcessInfo.processInfo.environment
let settings = Settings.load(from: UserDefaults(suiteName: SeckeyDialog.domain) ?? .standard, environment: environment)
let log = DebugLog(enabled: settings.debug)
let store = KeychainStore()
let detector = AppDetector(processes: SystemProcesses(), allowedApps: settings.allowedApps, log: log)

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

switch Mode(arguments: Array(CommandLine.arguments.dropFirst())) {
case .pinentry:
    log("pinentry started")
    let session = PinentrySession(dialogs: AppKitDialogs(), store: store, settings: settings, log: log) {
        detector.forPinentry(tty: $0.tty, ownerPid: $0.ownerPid)
    }
    say(session.greeting)
    while let line = readLine(strippingNewline: true) {
        let (responses, done) = session.handle(line)
        responses.forEach(say)
        if done { break }
    }

case .askpass(let message):
    let handler = AskpassHandler(
        dialogs: AppKitDialogs(), store: store, settings: settings, app: detector.forAskpass(), log: log,
        keyName: { KeyNames().name(for: $0) }, tokenSerial: { TokenSerial().current() })
    switch handler.handle(message: message, kind: AskpassKind(environment: environment)) {
    case .answer(let secret): say(secret)
    case .accepted: break
    case .refused: exit(1)
    }

case .command(let name, let arguments):
    exit(runCommand(name, arguments))
}
