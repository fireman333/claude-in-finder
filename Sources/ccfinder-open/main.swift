import AppKit
import CCFKit

/// "Claude in Finder.app" — a faceless helper with two jobs:
///
///   1. It is the LaunchServices handler for .claudesession, so double-clicking
///      a mirrored session fires the matching claude:// deep link.
///   2. It vends a Finder service ("New Claude Session Here") so you can
///      right-click a folder and start a session in it.
///
/// It has no UI of its own and quits as soon as it has handed off.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var handled = false
    private var idleExit: DispatchWorkItem?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Opened with no document (from Spotlight, or the app icon): show settings.
        // The wait has to outlast a cold launch — a service message can arrive well
        // after didFinishLaunching, and quitting first made the menu item look dead.
        let exit = DispatchWorkItem { [weak self] in
            guard let self, !self.handled else { return }
            self.claim()
            self.showSettings()
        }
        idleExit = exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: exit)
    }

    private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        let controller = SettingsWindowController()
        settings = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by every entry point the moment it takes charge.
    private func claim() {
        handled = true
        idleExit?.cancel()
        idleExit = nil
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        claim()
        Task {
            for url in urls {
                if let link = SessionFile.deepLink(for: url) {
                    let ok = await SessionFile.launch(link)
                    AppLog.write("open \(url.lastPathComponent) → \(link.absoluteString) [\(ok ? "ok" : "failed")]")
                } else {
                    AppLog.write("open \(url.lastPathComponent) → no session id")
                    await MainActor.run { Self.complain(about: url) }
                }
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    // MARK: - Finder service

    @objc func newSessionHere(_ pboard: NSPasteboard,
                              userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        claim()
        guard let folder = Self.folder(from: pboard) else {
            error.pointee = "No usable folder in the selection." as NSString
            NSApp.terminate(nil)
            return
        }
        guard let link = SessionFile.newSessionLink(cwd: folder) else {
            error.pointee = "Could not build the claude:// link." as NSString
            NSApp.terminate(nil)
            return
        }
        Task {
            let ok = await SessionFile.launch(link)
            AppLog.write("service new-session → \(folder) [\(ok ? "ok" : "failed")]")
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// Settings, reachable from any folder's contextual menu. The app has no Dock
    /// icon and quits as soon as it is done, so without an entry point like this
    /// there is nowhere to open it from.
    @objc func openSettingsService(_ pboard: NSPasteboard,
                                   userData: String,
                                   error: AutoreleasingUnsafeMutablePointer<NSString>) {
        claim()
        showSettings()
    }

    /// Opens the Archive folder for whatever was right-clicked — the point of
    /// hiding it rather than not creating it.
    @objc func openArchiveFolder(_ pboard: NSPasteboard,
                                 userData: String,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        claim()
        guard let folder = Self.folder(from: pboard) else {
            error.pointee = "No usable folder in the selection." as NSString
            NSApp.terminate(nil)
            return
        }
        let archive = URL(fileURLWithPath: folder)
            .appendingPathComponent(SessionFile.mirrorFolderName)
            .appendingPathComponent(SessionStore.archiveFolderName)

        if FileManager.default.fileExists(atPath: archive.path) {
            NSWorkspace.shared.open(archive)
            AppLog.write("opened archive: \(archive.path)")
        } else {
            error.pointee = "No archived sessions for \((folder as NSString).lastPathComponent)." as NSString
        }
        NSApp.terminate(nil)
    }

    // MARK: - Archive / delete services

    @objc func archiveSession(_ pboard: NSPasteboard,
                              userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        claim()
        act(on: pboard, error: error, verb: "archive")
    }

    @objc func deleteSession(_ pboard: NSPasteboard,
                             userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        claim()
        act(on: pboard, error: error, verb: "delete")
    }

    /// Both services share a shape: resolve the selection to session files, confirm
    /// once for the whole batch, act, then let the sync agent update the mirror.
    private func act(on pboard: NSPasteboard,
                     error: AutoreleasingUnsafeMutablePointer<NSString>,
                     verb: String) {
        let files = Self.sessionFiles(from: pboard)
        guard !files.isEmpty else {
            error.pointee = "No session files were selected." as NSString
            NSApp.terminate(nil)
            return
        }

        let targets: [(url: URL, id: String)] = files.compactMap { url in
            guard let id = SessionFile.meta(in: url)["claude-desktop-id"], !id.isEmpty else { return nil }
            return (url, id)
        }
        guard !targets.isEmpty else {
            error.pointee = "That is not a session file — \"+ New Session\" cannot be archived or deleted." as NSString
            NSApp.terminate(nil)
            return
        }

        guard confirm(verb: verb, targets: targets) else {
            NSApp.terminate(nil)
            return
        }

        var failures: [String] = []
        for target in targets {
            do {
                if verb == "archive" {
                    try SessionStore.archive(desktopID: target.id)
                    // Move it now rather than leaving a gap until the agent catches
                    // up: the folder should reflect the click immediately.
                    SessionStore.moveMirrorFile(target.url, intoArchive: true)
                } else {
                    try SessionStore.delete(desktopID: target.id)
                    // Recycle, not unlink: the file goes to the Trash.
                    NSWorkspace.shared.recycle([target.url])
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        AppLog.write("\(verb) \(targets.count) session(s), \(failures.count) failed")
        if !failures.isEmpty {
            error.pointee = failures.joined(separator: "\n") as NSString
        }
        NSApp.terminate(nil)
    }

    private func confirm(verb: String, targets: [(url: URL, id: String)]) -> Bool {
        let names = targets.prefix(5).map { SessionStore.title(desktopID: $0.id) ?? $0.url.lastPathComponent }
        var list = names.joined(separator: "\n")
        if targets.count > names.count { list += "\n… and \(targets.count - names.count) more" }

        let alert = NSAlert()
        alert.alertStyle = verb == "delete" ? .critical : .warning
        if verb == "archive" {
            alert.messageText = targets.count == 1 ? "Archive this session?" : "Archive these \(targets.count) sessions?"
            alert.informativeText = """
            \(list)

            It moves into the Archive folder and leaves Claude's session list.
            Nothing is deleted; drag it back out to unarchive.
            """
            alert.addButton(withTitle: "Archive")
        } else {
            alert.messageText = targets.count == 1 ? "Delete this session?" : "Delete these \(targets.count) sessions?"
            alert.informativeText = """
            \(list)

            It leaves Claude's session list and the file goes to the Trash.
            The conversation itself — the transcript under ~/.claude/projects —
            is not deleted, and the session record is backed up first.
            """
            alert.addButton(withTitle: "Delete")
        }
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func sessionFiles(from pboard: NSPasteboard) -> [URL] {
        var paths: [String] = []
        if let items = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            paths = items
        } else if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            paths = urls.map(\.path)
        }
        return paths.map { URL(fileURLWithPath: $0) }.filter { $0.pathExtension == "claudesession" }
    }

    /// Resolves what the user right-clicked into a real project directory,
    /// using the same rules as `ccfinder new`.
    private static func folder(from pboard: NSPasteboard) -> String? {
        var candidates: [String] = []
        if let items = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            candidates = items
        } else if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            candidates = urls.map(\.path)
        }
        guard let path = candidates.first else { return nil }
        return SessionFile.workingDirectory(for: path)
    }

    private static func complain(about url: URL) {
        let alert = NSAlert()
        alert.messageText = "Cannot open this session"
        alert.informativeText = """
        \(url.lastPathComponent) carries no session id.

        It may have been written by an older version, or the session it pointed
        at was deleted. Run `ccfinder sync` to regenerate it.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// Running the background sync as the app's own executable, rather than as a bare
// binary in Resources, is what makes it work at all under launchd: macOS grants
// file access per code identity, and a loose executable has none. Launched this
// way the process carries the app bundle's identity, so access to places like the
// Desktop follows the app — and can be granted in System Settings if it is not.
if CommandLine.arguments.contains("--watch") {
    // Run as an accessory app rather than a bare tool: it needs a menu bar item,
    // which is the only place settings can be opened from in an app with no Dock
    // icon. The watcher itself runs off the main thread so the UI stays live.
    let app = NSApplication.shared
    let delegate = AgentDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// The long-running half: sync agent plus menu bar item.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var watcher: Watcher?
    /// servicesProvider is held unowned, so the provider has to be kept alive here.
    private let services = AppDelegate()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.servicesProvider = services

        let watcher = Watcher(mirror: Mirror.fromConfig())
        self.watcher = watcher
        statusItem = StatusItemController { watcher.syncNow() }

        // The first pass reads several hundred files; keep it off the main thread
        // so the menu bar item appears immediately.
        DispatchQueue.global(qos: .utility).async { watcher.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app from Spotlight or the Finder reaches the already-running
    /// agent rather than starting a second copy, so the reopen has to be answered
    /// here — otherwise clicking the app appears to do nothing at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.showSettings()
        return true
    }

    /// A session file double-clicked while the agent is running is delivered here.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task {
            for url in urls where SessionFile.deepLink(for: url) != nil {
                if let link = SessionFile.deepLink(for: url) {
                    let ok = await SessionFile.launch(link)
                    AppLog.write("open \(url.lastPathComponent) → \(link.absoluteString) [\(ok ? "ok" : "failed")]")
                }
            }
        }
    }
}

enum AppLog {
    static func write(_ message: String) {
        let url = Paths.support.appendingPathComponent("ccfinder.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [app] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
