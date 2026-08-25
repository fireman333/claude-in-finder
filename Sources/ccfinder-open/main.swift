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

    /// Resolves what the user right-clicked into a real project directory.
    ///
    /// Inside the mirror the folders are display names, not real paths, so we
    /// follow the .ccf-project marker back to the directory the sessions
    /// actually ran in. Outside the mirror the selection is used as-is.
    private static func folder(from pboard: NSPasteboard) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let items = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            candidates = items
        } else if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            candidates = urls.map(\.path)
        }
        guard var path = candidates.first else { return nil }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            path = (path as NSString).deletingLastPathComponent
        }

        let marker = (path as NSString).appendingPathComponent(".ccf-project")
        if let real = try? String(contentsOfFile: marker, encoding: .utf8) {
            let trimmed = real.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, fm.fileExists(atPath: trimmed) { return trimmed }
        }
        return path
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()


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
