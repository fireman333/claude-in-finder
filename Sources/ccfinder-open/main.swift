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

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Opened with no document (e.g. from Spotlight): just reveal the mirror.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.handled else { return }
            NSWorkspace.shared.open(Paths.mirror)
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handled = true
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
        handled = true
        guard let folder = Self.folder(from: pboard) else {
            error.pointee = "找不到可用的資料夾" as NSString
            NSApp.terminate(nil)
            return
        }
        guard let link = SessionFile.newSessionLink(cwd: folder) else {
            error.pointee = "無法組出 claude:// 連結" as NSString
            NSApp.terminate(nil)
            return
        }
        Task {
            let ok = await SessionFile.launch(link)
            AppLog.write("service new-session → \(folder) [\(ok ? "ok" : "failed")]")
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    // MARK: - Archive / delete services

    @objc func archiveSession(_ pboard: NSPasteboard,
                              userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handled = true
        act(on: pboard, error: error, verb: "archive")
    }

    @objc func deleteSession(_ pboard: NSPasteboard,
                             userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handled = true
        act(on: pboard, error: error, verb: "delete")
    }

    /// Both services share a shape: resolve the selection to session files, confirm
    /// once for the whole batch, act, then let the sync agent update the mirror.
    private func act(on pboard: NSPasteboard,
                     error: AutoreleasingUnsafeMutablePointer<NSString>,
                     verb: String) {
        let files = Self.sessionFiles(from: pboard)
        guard !files.isEmpty else {
            error.pointee = "沒有選到 session 檔案" as NSString
            NSApp.terminate(nil)
            return
        }

        let targets: [(url: URL, id: String)] = files.compactMap { url in
            guard let id = SessionFile.meta(in: url)["claude-desktop-id"], !id.isEmpty else { return nil }
            return (url, id)
        }
        guard !targets.isEmpty else {
            error.pointee = "選到的檔案不是 session（「+ New Session」不能封存或刪除）" as NSString
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
                } else {
                    try SessionStore.delete(desktopID: target.id)
                }
                // Give immediate feedback rather than waiting on the sync agent.
                // Recycle, not unlink: the file goes to the Trash.
                NSWorkspace.shared.recycle([target.url])
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
        if targets.count > names.count { list += "\n⋯ 以及另外 \(targets.count - names.count) 個" }

        let alert = NSAlert()
        alert.alertStyle = verb == "delete" ? .critical : .warning
        if verb == "archive" {
            alert.messageText = targets.count == 1 ? "封存這個 session？" : "封存這 \(targets.count) 個 session？"
            alert.informativeText = """
            \(list)

            封存後會從 Claude 的清單和這個資料夾裡消失，對話內容不會被刪除。
            隨時可以用 ccfinder unarchive 還原。
            """
            alert.addButton(withTitle: "封存")
        } else {
            alert.messageText = targets.count == 1 ? "刪除這個 session？" : "刪除這 \(targets.count) 個 session？"
            alert.informativeText = """
            \(list)

            會從 Claude 的 session 清單移除，檔案移到垃圾桶。
            對話本身（~/.claude/projects 的 transcript）不會被刪除，
            session 記錄也會先備份到 ClaudeInFinder/deleted。
            """
            alert.addButton(withTitle: "刪除")
        }
        alert.addButton(withTitle: "取消")

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
        alert.messageText = "打不開這個 session"
        alert.informativeText = """
        \(url.lastPathComponent) 裡沒有可用的 session id。

        這個檔案可能是舊版產生的，或對應的 session 已被刪除。
        執行 `ccfinder sync` 重新產生一次。
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
    Watcher(mirror: Mirror.fromConfig()).run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
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
