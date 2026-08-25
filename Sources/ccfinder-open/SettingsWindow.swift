import AppKit
import CCFKit

/// The settings window, built in code so the project needs no nib and no Xcode.
///
/// Changing a setting applies it straight away — the files are rearranged by the
/// same reconcile the background agent runs — because a preference that needs a
/// separate "apply" step invites the two to disagree.
final class SettingsWindowController: NSWindowController {

    private var layoutPopUp: NSPopUpButton!
    private var archiveCheck: NSButton!
    private var deletePopUp: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var busy: NSProgressIndicator!

    private var quitsOnClose = true

    convenience init(quitsOnClose: Bool = true) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude in Finder"
        window.center()
        self.init(window: window)
        self.quitsOnClose = quitsOnClose
        buildContent()
        reloadStatus()
    }

    private func buildContent() {
        guard let window else { return }
        let content = NSView(frame: window.contentLayoutRect)
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = label("Settings", size: 15, weight: .semibold)

        let layoutTitle = label("Where session files are kept", size: 13, weight: .medium)
        layoutPopUp = NSPopUpButton()
        layoutPopUp.addItems(withTitles: [
            "In each working folder",
            "All together in ~/Claude Sessions",
        ])
        layoutPopUp.target = self
        layoutPopUp.action = #selector(layoutChanged)
        let layoutHelp = label(
            "A \"Claude Sessions\" folder is created next to the work each session belongs to.",
            size: 11, weight: .regular, secondary: true)
        layoutHelp.lineBreakMode = .byWordWrapping
        layoutHelp.usesSingleLineMode = false

        archiveCheck = NSButton(checkboxWithTitle: "Show the Archive folder",
                                target: self, action: #selector(archiveChanged))
        let archiveHelp = label(
            "Sessions you archived in Claude appear in an Archive subfolder. "
                + "Drag a session in or out of it to archive or unarchive it.",
            size: 11, weight: .regular, secondary: true)
        archiveHelp.lineBreakMode = .byWordWrapping
        archiveHelp.usesSingleLineMode = false

        let deleteTitle = label("Deleting a session file in Finder", size: 13, weight: .medium)
        deletePopUp = NSPopUpButton()
        deletePopUp.addItems(withTitles: ["Archives the session", "Deletes the session"])
        deletePopUp.target = self
        deletePopUp.action = #selector(deleteActionChanged)
        let deleteHelp = label(
            "Archiving keeps the conversation; deleting removes it from Claude's list "
                + "and backs the record up, leaving the transcript itself alone.",
            size: 11, weight: .regular, secondary: true)
        deleteHelp.lineBreakMode = .byWordWrapping
        deleteHelp.usesSingleLineMode = false

        statusLabel = label("", size: 11, weight: .regular, secondary: true)

        busy = NSProgressIndicator()
        busy.style = .spinning
        busy.controlSize = .small
        busy.isDisplayedWhenStopped = false

        let openButton = NSButton(title: "Open Claude Sessions",
                                  target: self, action: #selector(openMirror))
        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismiss))
        doneButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [openButton, NSView(), busy, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [
            title,
            layoutTitle, layoutPopUp, layoutHelp,
            archiveCheck, archiveHelp,
            deleteTitle, deletePopUp, deleteHelp,
            statusLabel,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(16, after: layoutHelp)
        stack.setCustomSpacing(16, after: archiveHelp)
        stack.setCustomSpacing(18, after: deleteHelp)
        stack.setCustomSpacing(14, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        window.contentView = content

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            layoutHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            archiveHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            deleteHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let config = Config.load()
        layoutPopUp.selectItem(at: config.layout == .workdir ? 0 : 1)
        archiveCheck.state = config.showArchive ? .on : .off
        deletePopUp.selectItem(at: config.onFinderDelete == .archive ? 0 : 1)
    }

    private func label(_ text: String, size: CGFloat,
                       weight: NSFont.Weight, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    // MARK: - Actions

    @objc private func layoutChanged() {
        var config = Config.load()
        config.layout = layoutPopUp.indexOfSelectedItem == 0 ? .workdir : .central
        apply(config)
    }

    @objc private func archiveChanged() {
        var config = Config.load()
        config.showArchive = archiveCheck.state == .on
        apply(config)
    }

    @objc private func deleteActionChanged() {
        var config = Config.load()
        config.onFinderDelete = deletePopUp.indexOfSelectedItem == 0 ? .archive : .delete
        apply(config)
    }

    @objc private func openMirror() {
        NSWorkspace.shared.open(Paths.mirror)
    }

    /// Saves, then rearranges the files on a background queue — moving several
    /// hundred of them takes long enough that doing it inline would freeze the
    /// window mid-click.
    private func apply(_ config: Config) {
        try? config.save()
        setBusy(true)
        statusLabel.stringValue = "Rearranging files…"

        DispatchQueue.global(qos: .userInitiated).async {
            let stats = try? Mirror.fromConfig().reconcile()
            DispatchQueue.main.async {
                self.setBusy(false)
                if let stats {
                    self.statusLabel.stringValue =
                        "Moved \(stats.renamed), added \(stats.created), removed \(stats.removed)."
                }
                self.reloadStatus(append: true)
            }
        }
    }

    private func setBusy(_ on: Bool) {
        layoutPopUp.isEnabled = !on
        archiveCheck.isEnabled = !on
        deletePopUp.isEnabled = !on
        on ? busy.startAnimation(nil) : busy.stopAnimation(nil)
    }

    private func reloadStatus(append: Bool = false) {
        DispatchQueue.global(qos: .utility).async {
            let sessions = Discovery.sessions()
            let active = sessions.filter { !$0.isArchived }.count
            let text = "\(sessions.count) sessions · \(active) active · "
                + "\(sessions.count - active) archived"
            DispatchQueue.main.async {
                if append, !self.statusLabel.stringValue.isEmpty {
                    self.statusLabel.stringValue += "  " + text
                } else {
                    self.statusLabel.stringValue = text
                }
            }
        }
    }

    @objc private func dismiss(_ sender: Any?) {
        window?.close()
        if quitsOnClose {
            NSApp.terminate(nil)
        } else {
            // Back to a menu-bar-only app; leaving it "regular" would strand an
            // empty app menu with no windows behind it.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
