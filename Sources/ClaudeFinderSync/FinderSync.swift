import Cocoa
import FinderSync
import CCFKit

/// A Finder Sync extension, which is the only way to put items in the contextual
/// menu itself rather than inside the Services submenu — and the only way to get a
/// menu when you right-click the empty background of a window.
@objc(ClaudeFinderSync)
final class ClaudeFinderSync: FIFinderSync {

    override init() {
        super.init()
        // Menus are only offered inside directories the extension monitors, and
        // sessions live wherever the work does — so it monitors the whole home
        // folder. Nothing is badged, so this costs no scanning.
        //
        // The path has to come from the password database: this process is
        // sandboxed, and every Foundation route to "home" hands back the sandbox
        // container instead, which is a folder nobody will ever right-click.
        let monitored: Set<URL> = [Self.realHome, URL(fileURLWithPath: "/Volumes")]
        FIFinderSyncController.default().directoryURLs = monitored
        Self.log("monitoring \(monitored.map(\.path).sorted().joined(separator: ", "))")
    }

    /// Writes to the same log the agent uses, so a silent extension can be told
    /// apart from one that never loaded.
    static func log(_ message: String) {
        let dir = realHome.appendingPathComponent("Library/Application Support/ClaudeInFinder")
        let url = dir.appendingPathComponent("ccfinder.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [ext] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The user's actual home directory, not the sandbox container.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "Claude in Finder")
        let controller = FIFinderSyncController.default()

        Self.log("menu(for: \(menuKind.rawValue)) target=\(controller.targetedURL()?.path ?? "nil")")

        switch menuKind {
        case .contextualMenuForItems:
            let selected = controller.selectedItemURLs() ?? []
            let sessions = selected.filter { $0.pathExtension == "claudesession" }
            if !sessions.isEmpty {
                add(menu, "Archive Claude Session", #selector(archive))
                add(menu, "Delete Claude Session", #selector(delete))
            } else if selected.allSatisfy(isDirectory) {
                addFolderItems(menu)
            }

        case .contextualMenuForContainer, .toolbarItemMenu:
            addFolderItems(menu)

        default:
            break
        }
        return menu
    }

    private func addFolderItems(_ menu: NSMenu) {
        add(menu, "New Claude Session Here", #selector(newSession))
        add(menu, "Open Claude Archive Folder", #selector(openArchive))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - Actions

    /// Whatever the click was aimed at: the selected folder, or the window's own
    /// folder when the click landed on empty space.
    private func targetFolder() -> String? {
        let controller = FIFinderSyncController.default()
        if let first = controller.selectedItemURLs()?.first, isDirectory(first) {
            return SessionFile.workingDirectory(for: first.path)
        }
        guard let container = controller.targetedURL() else { return nil }
        return SessionFile.workingDirectory(for: container.path)
    }

    @objc private func newSession() {
        guard let folder = targetFolder(),
              let link = SessionFile.newSessionLink(cwd: folder) else { return }
        NSWorkspace.shared.open(link)
    }

    @objc private func openArchive() {
        guard let folder = targetFolder() else { return }
        let archive = URL(fileURLWithPath: folder)
            .appendingPathComponent(SessionFile.mirrorFolderName)
            .appendingPathComponent(SessionStore.archiveFolderName)
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        NSWorkspace.shared.open(archive)
    }

    @objc private func archive() { send(verb: "archive") }
    @objc private func delete() { send(verb: "delete") }

    /// Destructive actions go to the app rather than happening here: the extension
    /// has no business showing a confirmation sheet, and the app is already the
    /// place that asks.
    private func send(verb: String) {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        let sessions = selected.filter { $0.pathExtension == "claudesession" }
        guard !sessions.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "ccfinder"
        components.host = verb
        components.queryItems = sessions.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
