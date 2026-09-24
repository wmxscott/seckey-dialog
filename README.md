# seckey-dialog

[![CI](https://github.com/wmxscott/seckey-dialog/actions/workflows/ci.yml/badge.svg)](https://github.com/wmxscott/seckey-dialog/actions/workflows/ci.yml)

Native macOS dialogs for hardware security keys: one small program that answers both gpg-agent and ssh when they need you.

- **gpg-agent** (as its `pinentry-program`): PINs for OpenPGP and PIV smartcards such as a YubiKey, and passphrases for GPG keys.
- **ssh** (as `SSH_ASKPASS`): a "touch your security key" notice that closes itself the moment you touch the key, FIDO2 PIN prompts, and confirmations.

Every dialog says which key is asking and which app the request came from. Only one dialog shows at a time, however many requests arrive together.

> **Security:** seckey-dialog can save PINs in your keychain, but this is **off by default**. Read [SECURITY.md](SECURITY.md) before turning it on.

## Why

macOS has no built-in graphical askpass, so ssh can't show a prompt outside a terminal. Git in an editor or a background fetch just fails, or hangs waiting for a touch you never knew was needed. [pinentry-mac](https://github.com/GPGTools/pinentry) covers gpg-agent but not ssh. seckey-dialog covers both with the same native dialogs.

## Install

```sh
brew install wmxscott/tap/seckey-dialog
```

Needs macOS 13 or later. To build from source instead:

```sh
git clone https://github.com/wmxscott/seckey-dialog.git
cd seckey-dialog
swift build --configuration release
install "$(swift build --configuration release --show-bin-path)/seckey-dialog" ~/.local/bin/
```

## Set up

Point each tool at the full path. With Homebrew that's `$(brew --prefix)/opt/seckey-dialog/bin/seckey-dialog`, which stays the same across upgrades. On Apple silicon it's `/opt/homebrew/opt/seckey-dialog/bin/seckey-dialog`.

### gpg-agent

Add to `~/.gnupg/gpg-agent.conf`:

```
pinentry-program /opt/homebrew/opt/seckey-dialog/bin/seckey-dialog
```

Then restart the agent with `gpgconf --kill gpg-agent`. It starts again when next needed.

### ssh

ssh runs the askpass program named in `SSH_ASKPASS`. For security keys, whatever runs ssh-agent must have both of these set, because that's where the touch and PIN requests come from:

```sh
SSH_ASKPASS=/opt/homebrew/opt/seckey-dialog/bin/seckey-dialog
SSH_ASKPASS_REQUIRE=force
```

If you run your own ssh-agent from a launch agent, put them in its `EnvironmentVariables`. For ssh used without an agent, export them in your shell.

## What you'll see

| Request | Dialog |
|---|---|
| Touch needed (FIDO2) | "Touch your security key…", naming the key by the comment in its `~/.ssh/*.pub` file. It closes by itself when you touch the key. Cancel just hides it; ssh keeps waiting for the touch |
| PIN (FIDO2, OpenPGP, PIV) | A PIN field |
| Key passphrase | A passphrase field. These are never saved |
| New passphrase (from gpg) | Two fields that must match |
| Confirmation | OK / Cancel |

"Requested by" names the app the request came from. seckey-dialog finds it by walking up from the requesting process to the first app in `AllowedApps`. With a terminal, that's usually the terminal itself.

## Settings

Settings live in the `io.github.wmxscott.seckey-dialog` defaults domain. `seckey-dialog settings` shows the current values.

| Setting | Default | |
|---|---|---|
| `AllowedApps` | Terminal, iTerm2, Ghostty, WezTerm, kitty, Alacritty, Warp, Zed, VS Code, Cursor | Apps requests are credited to. An entry ending in `.app` matches anything running inside that app bundle. Any other entry matches a program by name, such as `tmux` |
| `IconPath` | built-in key icon | Image shown when the request can't be tied to an app |
| `SavePINs` | off | Offer to save PINs in the keychain. See [SECURITY.md](SECURITY.md) first |
| `Debug` | off | Log each request to `$TMPDIR/seckey-dialog.log`. PINs and passphrases are never logged. `SECKEY_DIALOG_DEBUG=1` does the same for one run |

```sh
defaults write io.github.wmxscott.seckey-dialog AllowedApps -array Ghostty.app "Visual Studio Code.app" tmux
defaults write io.github.wmxscott.seckey-dialog IconPath ~/Pictures/yubikey.png
```

## Saved PINs

With `SavePINs` on, PIN dialogs get a **Save in keychain** checkbox. A saved PIN is filed under the key and the app it was entered for, so it's only used for that key and that app:

| Account | For |
|---|---|
| `gpg:<keygrip>:<app>` | An OpenPGP key |
| `piv:<card serial>:<app>` | A PIV smartcard |
| `fido2:<serial>:<app>` | A FIDO2 key. The serial comes from `ykman` if it's installed, so two keys with different PINs don't mix. Without it, `fido2:<app>` |

`seckey-dialog list` shows them, and `seckey-dialog remove <account>` or `remove --all` deletes them. Read [SECURITY.md](SECURITY.md) for what saving costs.

## Commands

gpg-agent and ssh run seckey-dialog themselves. These are for you:

| Command | |
|---|---|
| `seckey-dialog settings` | Show the settings and how to change them |
| `seckey-dialog list` | List saved PINs by name |
| `seckey-dialog remove <account>` / `--all` | Delete saved PINs |
| `seckey-dialog test <account>` | Check a saved PIN can be read, without showing it |
| `seckey-dialog test-detect [tty]` | Show which app a request from this terminal would be credited to |
| `seckey-dialog test-pin`, `test-touch`, `test-confirm` | Show a sample dialog |

## How it works

Neither gpg-agent nor ssh passes options to the program they run, so seckey-dialog works out its job from how it's started:

- **No arguments:** gpg-agent is about to speak the [Assuan](https://www.gnupg.org/documentation/manuals/assuan/) pinentry protocol on standard input.
- **A prompt as the argument:** ssh wants something, and `SSH_ASKPASS_PROMPT` says what: `none` for a touch notice, `confirm` for yes/no, unset for a secret.
- **One of the commands above:** management.

ssh-agent ends a touch notice by sending it `SIGTERM` once the key is touched. The dialog runs a modal loop that ignores ordinary events, so a signal handler sets a flag and a timer inside that loop closes the dialog.

## Development

```sh
swift build
swift test          # use Xcode's toolchain; the Command Line Tools may lack Swift Testing's macros
swift format lint --strict --recursive Sources Tests Package.swift
```

`SeckeyDialogCore` holds everything except the AppKit dialogs: the pinentry protocol, askpass handling, app detection and settings. The tests drive it through fake dialogs, a fake keychain and a fake process tree, so nothing appears on screen. One test uses the real login keychain under a throwaway service name.

## License

[MIT](LICENSE)
