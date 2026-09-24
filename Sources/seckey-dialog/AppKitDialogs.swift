import AppKit
import SeckeyDialogCore

/// Set from a signal handler, which is the only code that runs reliably while `runModal()`
/// owns the thread. Only ever written with a plain store, which is async-signal-safe.
nonisolated(unsafe) var touchSignalled: sig_atomic_t = 0

/// Native alerts. One at a time across every running copy, via a lock file.
@MainActor
final class AppKitDialogs: Dialogs {
    let lockPath: String

    init(lockPath: String = NSHomeDirectory() + "/.cache/seckey-dialog/dialog.lock") {
        self.lockPath = lockPath
    }

    private func bringToFront() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func image(_ icon: DialogIcon) -> NSImage? {
        switch icon {
        case .app(let path): NSWorkspace.shared.icon(forFile: path)
        case .file(let path): NSImage(contentsOfFile: path)
        case .standard: NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Security key")
        }
    }

    private func alert(_ title: String, _ message: String, _ icon: DialogIcon) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        if let image = image(icon) { alert.icon = image }
        return alert
    }

    func askSecret(_ request: SecretRequest) -> SecretAnswer? {
        withExclusiveLock(at: lockPath) {
            bringToFront()
            let alert = alert(request.title, request.message, request.icon)
            alert.addButton(withTitle: request.okLabel)
            alert.addButton(withTitle: request.cancelLabel)

            let width: CGFloat = 300
            let rowHeight: CGFloat = 28
            let gap: CGFloat = 8
            let rows = 1 + (request.repeatLabel == nil ? 0 : 1) + (request.offerSave ? 1 : 0)
            let view = NSView(
                frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap))
            var y: CGFloat = 0

            var saveBox: NSButton?
            if request.offerSave {
                let box = NSButton(checkboxWithTitle: "Save in keychain", target: nil, action: nil)
                box.frame = NSRect(x: 0, y: y, width: width, height: rowHeight)
                box.toolTip = "Anyone logged in as you could then use your key without knowing the PIN."
                view.addSubview(box)
                saveBox = box
                y += rowHeight + gap
            }

            var repeatField: NSSecureTextField?
            if let repeatLabel = request.repeatLabel {
                let field = NSSecureTextField(frame: NSRect(x: 0, y: y, width: width, height: rowHeight - 4))
                field.placeholderString = repeatLabel
                view.addSubview(field)
                repeatField = field
                y += rowHeight + gap
            }

            let field = NSSecureTextField(frame: NSRect(x: 0, y: y, width: width, height: rowHeight - 4))
            field.placeholderString = request.label.isEmpty ? "Passphrase" : request.label
            view.addSubview(field)
            alert.accessoryView = view
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return SecretAnswer(
                secret: field.stringValue, repeated: repeatField?.stringValue, save: saveBox?.state == .on)
        }
    }

    func confirm(title: String, message: String, okLabel: String, cancelLabel: String, icon: DialogIcon) -> Bool {
        withExclusiveLock(at: lockPath) {
            bringToFront()
            let alert = alert(title, message, icon)
            alert.addButton(withTitle: okLabel)
            alert.addButton(withTitle: cancelLabel)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// ssh-agent sends SIGTERM once the key is touched or the request times out. `runModal()`
    /// runs its own run loop, so a timer in that loop's mode polls the flag the handler sets.
    func touch(title: String, message: String, icon: DialogIcon) -> Bool {
        withExclusiveLock(at: lockPath) {
            bringToFront()
            touchSignalled = 0
            signal(SIGTERM) { _ in touchSignalled = 1 }
            defer { signal(SIGTERM, SIG_DFL) }

            let alert = alert(title, message, icon)
            alert.addButton(withTitle: "Cancel")
            let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                guard touchSignalled != 0 else { return }
                timer.invalidate()
                MainActor.assumeIsolated { NSApp.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let response = alert.runModal()
            timer.invalidate()
            return touchSignalled != 0 || response == .abort
        }
    }
}
