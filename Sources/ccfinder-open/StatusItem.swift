import AppKit
import CCFKit

/// The menu bar item, owned by the background sync process.
///
/// That process is the one already running all the time, so it is the natural
/// home for the app's only piece of persistent UI. Without it there is nowhere
/// to open settings from: the app has no Dock icon and quits as soon as it has
/// handled whatever it was launched for.
final class StatusItemController: NSObject {

    private let item: NSStatusItem
    private var settings: SettingsWindowController?
    private let onSyncNow: () -> Void

    init(onSyncNow: @escaping () -> Void) {
        self.onSyncNow = onSyncNow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            let symbol = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Claude in Finder")
            button.image = symbol ?? Self.fallbackIcon()
            button.image?.isTemplate = true
            // Without content the item is zero-width, which looks exactly like a
            // status item that failed to appear.
            if button.image == nil { button.title = "CF" }
            button.toolTip = "Claude in Finder"
            Log.line("status item: image=\(button.image != nil), symbol=\(symbol != nil)")
        } else {
            Log.line("status item: no button — the item was not created")
        }

        item.menu = buildMenu()
        refreshUpdateBadge()
    }

    /// A dot beside the icon is the whole of the reminder: enough to notice on
    /// the next glance at the menu bar, and nothing that interrupts.
    func refreshUpdateBadge() {
        guard let button = item.button, button.image != nil else { return }
        if let release = Update.pending {
            // Drawn small on purpose: at the menu bar's own text size the dot is
            // a blob next to the icon rather than a badge on it.
            button.attributedTitle = NSAttributedString(
                string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 7)])
            button.toolTip = "Claude in Finder — \(release.version) is available"
        } else {
            button.title = ""
            button.toolTip = "Claude in Finder"
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = Tag.status
        menu.addItem(status)

        // Carried hidden rather than inserted and removed, so its position in the
        // menu never moves under the pointer.
        let update = NSMenuItem(title: "", action: #selector(openRelease), keyEquivalent: "")
        update.target = self
        update.tag = Tag.update
        update.isHidden = true
        menu.addItem(update)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Open Claude Sessions",
                     action: #selector(openMirror), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sync Now",
                     action: #selector(syncNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…",
                     action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude in Finder",
                     action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    private enum Tag { static let status = 1; static let update = 2 }

    /// A speech bubble drawn by hand, in case the SF Symbol is unavailable.
    private static func fallbackIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 14, height: 10),
                                xRadius: 3, yRadius: 3)
        body.fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4, y: 4.5))
        tail.line(to: NSPoint(x: 4, y: 1))
        tail.line(to: NSPoint(x: 8, y: 4.5))
        tail.close()
        tail.fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Actions

    @objc private func openMirror() {
        NSWorkspace.shared.open(Paths.mirror)
    }

    @objc private func syncNow() {
        onSyncNow()
    }

    @objc func showSettings() {
        // An accessory app has no menu bar of its own, so it must be promoted
        // before it can show and focus a real window.
        NSApp.setActivationPolicy(.regular)
        if settings == nil { settings = SettingsWindowController(quitsOnClose: false) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openRelease() {
        let url = Update.pending.flatMap { URL(string: $0.url) } ?? Update.releasesPage
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Counts are read when the menu opens rather than kept up to date, which
    /// would mean waking up to recount on every change for something nobody is
    /// looking at.
    func menuWillOpen(_ menu: NSMenu) {
        if let update = menu.item(withTag: Tag.update) {
            let release = Update.pending
            update.title = release.map { "Update to \($0.version)…" } ?? ""
            update.isHidden = release == nil
        }
        refreshUpdateBadge()

        guard let status = menu.item(withTag: Tag.status) else { return }
        status.title = "Counting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = Discovery.sessions()
            let active = sessions.filter { !$0.isArchived }.count
            let text = "\(active) active · \(sessions.count - active) archived"
            DispatchQueue.main.async { status.title = text }
        }
    }
}
