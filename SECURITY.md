# Security

## Advisory: saving PINs in the keychain

seckey-dialog can save a security key's PIN in your login keychain, so it fills itself in next time. **This is off by default, and you should leave it off unless you've read this and accept the trade.**

### What saving changes

A security key normally needs two things: the key itself, and a PIN that only you know. With a saved PIN, the PIN step is only as strong as your login session. Anyone, or any program, that is running as you and can get seckey-dialog to answer, now has the PIN.

That's easier than it sounds. gpg-agent and ssh ask for a PIN by running seckey-dialog, and seckey-dialog answers from the keychain when the request comes from an app in `AllowedApps`. It can't tell a genuine request from gpg or ssh apart from a malicious script started in the same terminal. So with saving on:

- **Any program you run inside a recognised app can obtain a saved PIN**, for example a compromised dependency in a build script or a malicious shell plugin. It needs no keychain prompt: to macOS, seckey-dialog is reading its own item.
- **Keychain prompts become routine.** Homebrew builds aren't signed with an Apple Developer ID, so macOS ties saved items to one exact build. After each upgrade, it asks once to let the new build read them. If clicking "Always Allow" becomes a habit, you may click it for something that isn't seckey-dialog.

What saving doesn't change: a key that requires a touch still needs the touch, and a key that's unplugged still can't be used. A saved PIN on its own is not the key.

### If you turn it on

- Keep `AllowedApps` to the apps you actually use for git and ssh. Every entry is another place a request can come from.
- Prefer keys and credentials that also need a touch, so a leaked PIN still needs you at the key.
- Only save PINs on a machine you alone use.
- Read the text of every keychain prompt, especially just after an upgrade.

```sh
defaults write io.github.wmxscott.seckey-dialog SavePINs -bool true    # turn on
defaults delete io.github.wmxscott.seckey-dialog SavePINs              # turn off
seckey-dialog list                                                    # see what's saved (names only)
seckey-dialog remove --all                                            # delete every saved PIN
```

Turning saving off stops seckey-dialog from reading saved PINs as well as writing them, but leaves them in the keychain until you remove them.

### What seckey-dialog never does

- It never saves a passphrase for a key file, only security key PINs.
- It never writes a PIN or passphrase to its debug log.
- It never prints a saved PIN from its management commands. `list` shows account names, and `test` only reports whether an entry can be read.

## Reporting a vulnerability

Please report security problems privately, through **Report a vulnerability** on the repository's [Security tab](https://github.com/wmxscott/seckey-dialog/security), not in a public issue.
