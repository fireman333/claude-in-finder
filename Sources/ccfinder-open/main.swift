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
        if let request = urls.compactMap(Self.controlRequest).first {
            act(verb: request.verb, files: request.files)
            return
        }
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
        act(verb: verb, files: files, error: error)
    }

    /// The Finder extension cannot put a confirmation sheet on screen, so it hands
    /// destructive actions back here through the ccfinder:// scheme.
    func act(verb: String, files: [URL], quitWhenDone: Bool = true) {
        act(verb: verb, files: files, error: nil, quitWhenDone: quitWhenDone)
    }

    private func act(verb: String, files: [URL],
                     error: AutoreleasingUnsafeMutablePointer<NSString>?,
                     quitWhenDone: Bool = true) {
        func fail(_ message: String) {
            error?.pointee = message as NSString
            if quitWhenDone { NSApp.terminate(nil) }
        }

        let targets: [(url: URL, id: String)] = files.compactMap { url in
            guard let id = SessionFile.meta(in: url)["claude-desktop-id"], !id.isEmpty else { return nil }
            return (url, id)
        }
        guard !targets.isEmpty else {
            fail("That is not a session file — \"+ New Session\" cannot be archived or deleted.")
            return
        }

        guard confirm(verb: verb, targets: targets) else {
            if quitWhenDone { NSApp.terminate(nil) }
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
            error?.pointee = failures.joined(separator: "\n") as NSString
        }
        if quitWhenDone { NSApp.terminate(nil) }
    }

    /// Parses ccfinder://archive?path=…&path=… into a verb and its files.
    static func controlRequest(from url: URL) -> (verb: String, files: [URL])? {
        guard url.scheme == "ccfinder",
              let host = url.host, ["archive", "delete"].contains(host),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let files = items.filter { $0.name == "path" }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0) }
        return files.isEmpty ? nil : (host, files)
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
if CommandLine.arguments.contains("--request-access") {
    // Touch the folders macOS protects so it raises its consent prompts now, while
    // the user is still at the keyboard, instead of at some later moment when the
    // background agent quietly finds a folder it cannot read.
    //
    // This is needed after every update: the app is ad-hoc signed, so its identity
    // is its code hash, and a rebuild is a different app as far as TCC is concerned.
    let home = FileManager.default.homeDirectoryForCurrentUser
    var blocked: [String] = []
    for name in ["Desktop", "Documents", "Downloads"] {
        let dir = home.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: dir.path) else { continue }
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == nil {
            blocked.append(name)
        }
    }
    if !blocked.isEmpty {
        let alert = NSAlert()
        alert.messageText = "Claude in Finder needs access to \(blocked.joined(separator: ", "))"
        alert.informativeText = """
        Sessions that live in those folders cannot be synced until access is granted.

        Open System Settings → Privacy & Security → Files and Folders (or Full Disk \
        Access) and allow Claude in Finder, then run the installer again.

        Everything else keeps working in the meantime.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    exit(0)
} else if CommandLine.arguments.contains("--watch") {
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

        let watcher = Watcher(mirror: { Mirror.fromConfig() })
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

    /// Session files double-clicked, and ccfinder:// requests from the Finder
    /// extension, both arrive here while the agent is running.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let request = urls.compactMap(AppDelegate.controlRequest).first {
            services.act(verb: request.verb, files: request.files, quitWhenDone: false)
            return
        }
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
