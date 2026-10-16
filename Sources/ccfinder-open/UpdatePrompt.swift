import AppKit
import CCFKit

/// "Update to 0.12.6…": asks first, then installs.
///
/// Asking is the point. The app is ad-hoc signed and installing it restarts
/// Finder, so an update happens when you say so and not before — the reminder
/// stays a reminder until you click it.
enum UpdatePrompt {
    /// Set while a download is under way, so a second click does not start
    /// a second one.
    private(set) static var busy = false

    static func offer(_ release: Update.Release) {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "Update Claude in Finder to \(release.version)?"
        alert.informativeText = """
            The update is downloaded from GitHub, checked against the checksum \
            GitHub records for it, and installed. Finder restarts while it is \
            installed. Afterwards, Settings → Permissions shows whether folder \
            access needs allowing again.
            """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Cancel")
        switch present(alert) {
        case .alertFirstButtonReturn:
            install()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: release.url) ?? Update.releasesPage)
        default:
            break
        }
    }

    /// Shown in front even from an app with no Dock icon: an accessory app's
    /// modal alert can otherwise open behind whatever is in use, and wait there
    /// unseen.
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            NSApp.setActivationPolicy(.accessory)
        }
        return response
    }

    private static func install() {
        busy = true
        // If the installer fails before it gets as far as replacing this app,
        // nothing comes back to say so; stop showing "Downloading…" for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10 * 60) { busy = false }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Void in
                // Asked again rather than taken from the cache, which may predate
                // the release now out or lack the image to install.
                guard case .available(let latest) = try Update.check() else {
                    throw UpdateInstaller.Failure(message: "this is already the latest version")
                }
                try UpdateInstaller.install(latest)
            }
            // On success there is nothing to do: the installer is about to stop
            // this app and start the new one.
            guard case .failure(let error) = result else { return }
            DispatchQueue.main.async {
                busy = false
                var reason = error.localizedDescription
                while reason.hasSuffix(".") { reason.removeLast() }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The update was not installed"
                alert.informativeText = """
                    \(reason.prefix(1).uppercased())\(reason.dropFirst()). Nothing was changed; \
                    you can install it by hand from the release page.
                    """
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Close")
                if present(alert) == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(Update.pending.flatMap { URL(string: $0.url) }
                                            ?? Update.releasesPage)
                }
            }
        }
    }
}
