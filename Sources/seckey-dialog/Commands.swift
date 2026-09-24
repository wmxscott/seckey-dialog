import Foundation
import SeckeyDialogCore

let usage = """
    seckey-dialog \(SeckeyDialog.version): native macOS PIN, passphrase and touch prompts for
    gpg-agent (pinentry) and ssh (askpass).

    Setup:
      ~/.gnupg/gpg-agent.conf    pinentry-program <path to seckey-dialog>
      ssh-agent's environment    SSH_ASKPASS=<path to seckey-dialog>
                                 SSH_ASKPASS_REQUIRE=force

    Commands:
      settings                   Show the current settings and how to change them
      list                       List saved PINs (names only)
      remove <account> | --all   Delete one saved PIN, or all of them
      test <account>             Check a saved PIN can be read
      test-detect [tty]          Show which app a request from this terminal is credited to
      test-pin | test-touch | test-confirm
                                 Show a sample dialog
      --version | help

    Saving PINs is off by default. Read the security note before turning it on:
    https://github.com/wmxscott/seckey-dialog/blob/main/SECURITY.md
    """

@MainActor
func runCommand(_ name: String, _ arguments: [String]) -> Int32 {
    let argument = arguments.first ?? ""
    switch name {
    case "settings":
        printSettings()
    case "list":
        let accounts = store.accounts()
        if accounts.isEmpty {
            print("No saved PINs.")
        } else {
            for account in accounts { print(account) }
            if !settings.savePINs {
                print("\nSaving PINs is off, so these are ignored. Delete them with `seckey-dialog remove --all`.")
            }
        }
    case "remove":
        if argument == "--all" {
            let accounts = store.accounts()
            for account in accounts { store.delete(account) }
            print("Removed \(accounts.count) saved PIN(s).")
        } else if argument.isEmpty {
            print("usage: seckey-dialog remove <account> | --all")
            return 64
        } else {
            guard store.delete(argument) else {
                print("No saved PIN named \(argument).")
                return 1
            }
            print("Removed \(argument).")
        }
    case "test":
        guard !argument.isEmpty else {
            print("usage: seckey-dialog test <account>")
            return 64
        }
        let readable = store.secret(for: argument) != nil
        print(readable ? "OK: \(argument)" : "Not readable: \(argument)")
        return readable ? 0 : 1
    case "test-detect":
        let tty =
            argument.isEmpty
            ? CommandRunner().run("/usr/bin/tty", []).output.trimmingCharacters(in: .whitespacesAndNewlines)
            : argument
        guard let app = detector.forPinentry(tty: tty, ownerPid: 0) else {
            print("No recognised app. Recognised: \(settings.allowedApps.joined(separator: ", "))")
            return 1
        }
        print("Detected \(app.id)\(app.path.map { " (\($0))" } ?? "")")
    case "test-pin":
        let answer = AppKitDialogs().askSecret(
            SecretRequest(
                title: "Test PIN", message: "A sample PIN dialog.", label: "PIN", offerSave: settings.savePINs,
                icon: settings.icon(for: nil)))
        print(answer.map { "Entered \($0.secret.count) characters, save: \($0.save)" } ?? "Cancelled")
    case "test-touch":
        print("Dismiss with Cancel, or: kill -TERM \(getpid())")
        let signalled = AppKitDialogs().touch(
            title: "SSH Authentication", message: "Touch your security key…", icon: settings.icon(for: nil))
        print(signalled ? "Dismissed by signal" : "Cancelled")
    case "test-confirm":
        let ok = AppKitDialogs().confirm(
            title: "Test", message: "A sample confirmation.", okLabel: "OK", cancelLabel: "Cancel",
            icon: settings.icon(for: nil))
        print(ok ? "Confirmed" : "Cancelled")
    case "--version", "-V":
        print("seckey-dialog \(SeckeyDialog.version)")
    default:
        print(usage)
    }
    return 0
}

@MainActor
func printSettings() {
    let domain = SeckeyDialog.domain
    print(
        """
        SavePINs      \(settings.savePINs ? "on" : "off")
        AllowedApps   \(settings.allowedApps.joined(separator: ", "))
        IconPath      \(settings.iconPath ?? "(built-in key icon)")
        Debug         \(settings.debug ? "on, logging to \(log.path)" : "off")

        Change with `defaults write \(domain) <setting> <value>`, for example:
          defaults write \(domain) AllowedApps -array Ghostty.app Zed.app tmux
          defaults write \(domain) IconPath ~/Pictures/key.png
          defaults write \(domain) Debug -bool true
          defaults write \(domain) SavePINs -bool true   # read SECURITY.md first
        """)
}
