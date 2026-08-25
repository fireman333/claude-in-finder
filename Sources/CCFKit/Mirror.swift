import Foundation
import CryptoKit

/// Mirrors Claude Desktop's sessions as .claudesession files.
///
/// Files live in a "Claude Sessions" folder inside the directory the session
/// actually ran in, so they sit next to the work they belong to. Sessions whose
/// working directory is gone fall back to a folder under the central mirror,
/// which is also where everything lands in `--central` mode.
///
/// State is kept in index.json so that a retitled session becomes a *move* of
/// the existing file rather than a delete + create. That matters: moving keeps
/// the file's Finder tags, comments and any aliases the user made to it.
public struct Mirror {

    /// Name of the per-project folder dropped inside each working directory.
    static let folderName = SessionFile.mirrorFolderName
    /// Sessions archived in Claude are kept, but tucked one level down.
    static let archiveFolderName = SessionStore.archiveFolderName

    struct Entry: Codable {
        var path: String      // absolute since v2; relative to the mirror root in v1
        var title: String
        var hash: String
    }

    struct Index: Codable {
        var version: Int = 2
        var entries: [String: Entry] = [:]   // keyed by desktop session id
    }

    /// Leave archived sessions out of the mirror entirely.
    public var skipArchived: Bool
    public var prune: Bool
    public var verbose: Bool
    /// Put everything under the central mirror instead of inside working directories.
    public var central: Bool = false
    /// Add "Claude Sessions/" to .git/info/exclude so the files stay out of git status.
    public var gitExclude: Bool = true

    let fm = FileManager.default

    public init(skipArchived: Bool, prune: Bool, verbose: Bool,
                central: Bool = false, gitExclude: Bool = true) {
        self.skipArchived = skipArchived
        self.prune = prune
        self.verbose = verbose
        self.central = central
        self.gitExclude = gitExclude
    }

    /// Builds a mirror from the saved settings, with optional per-run overrides.
    public static func fromConfig(forceCentral: Bool = false,
                                  forceSkipArchived: Bool = false,
                                  prune: Bool = true,
                                  gitExclude: Bool = true,
                                  verbose: Bool = false) -> Mirror {
        let config = Config.load()
        return Mirror(
            skipArchived: forceSkipArchived || !config.showArchive,
            prune: prune,
            verbose: verbose,
            central: forceCentral || config.layout == .central,
            gitExclude: gitExclude
        )
    }

    // MARK: - Entry point

    @discardableResult
    public func reconcile() throws -> (created: Int, renamed: Int, updated: Int, removed: Int) {
        try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)

        var index = loadIndex()
        applyDragIntent(index: index)
        adoptOrphans(into: &index)
        let transcripts = Discovery.transcriptIndex()

        var sessions = Discovery.sessions()
        if skipArchived { sessions.removeAll { $0.isArchived } }

        let fallbackNames = fallbackFolderNames(for: sessions)
        var stats = (created: 0, renamed: 0, updated: 0, removed: 0)
        var live = Set<String>()
        var usedPaths = Set<String>()
        var roots = Set<URL>()

        // Newest first so that, on a filename clash, the session you touched most
        // recently keeps the clean name and the older one gets the suffix.
        for session in sessions.sorted(by: { $0.sortDate > $1.sortDate }) {
            live.insert(session.desktopID)

            let root = self.root(for: session, fallbackNames: fallbackNames)
            var name = Self.sanitize(session.title)
            var dest = root.appendingPathComponent("\(name).claudesession")
            if usedPaths.contains(dest.path) {
                name += " · \(String((session.cliSessionID ?? session.desktopID).prefix(6)))"
                dest = root.appendingPathComponent("\(name).claudesession")
            }
            usedPaths.insert(dest.path)

            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            roots.insert(root)

            let content = Render.html(for: session, transcript: transcripts[session.cliSessionID ?? ""])
            let hash = Self.digest(content)

            let previous = index.entries[session.desktopID]
            let oldURL = previous.map { URL(fileURLWithPath: $0.path) }

            // Retitled, or the layout changed under it: move the existing file so
            // Finder metadata survives.
            if let previous, let oldURL, previous.path != dest.path, fm.fileExists(atPath: oldURL.path) {
                do {
                    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                    try fm.moveItem(at: oldURL, to: dest)
                    stats.renamed += 1
                    log("moved: \(previous.path) → \(dest.path)")
                    pruneEmptyParent(of: oldURL)
                } catch {
                    // Fall through and write a fresh file; a single stubborn path
                    // should not take the rest of the sync down with it.
                    log("move failed (\(error.localizedDescription)); rewriting instead")
                }
            }

            if !fm.fileExists(atPath: dest.path) {
                try write(content, to: dest)
                stats.created += 1
                log("created: \(dest.path)")
            } else if previous?.hash != hash {
                try write(content, to: dest)
                stats.updated += 1
            }

            index.entries[session.desktopID] = Entry(path: dest.path, title: session.title, hash: hash)
        }

        // Remove mirror files for sessions that are gone. Only files we created and
        // still track are touched, so anything the user dropped in here is safe.
        if prune {
            for (id, entry) in index.entries where !live.contains(id) {
                let url = URL(fileURLWithPath: entry.path)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                    pruneEmptyParent(of: url)
                    stats.removed += 1
                    log("removed: \(entry.path)")
                }
                index.entries.removeValue(forKey: id)
            }
        }

        try writeFolderExtras(roots: roots, sessions: sessions, fallbackNames: fallbackNames)
        try saveIndex(index)
        return stats
    }

    // MARK: - Where a session's file belongs

    private func root(for session: Session, fallbackNames: [String: String]) -> URL {
        let main = mainRoot(cwd: session.cwd, fallbackNames: fallbackNames)
        return session.isArchived ? main.appendingPathComponent(Self.archiveFolderName) : main
    }

    /// The folder a project's live sessions go in. Archived ones sit one level
    /// below it, which is what makes archiving from Finder a plain file move.
    private func mainRoot(cwd: String, fallbackNames: [String: String]) -> URL {
        if !central, !cwd.isEmpty {
            var isDir: ObjCBool = false
            if !Self.blocked.contains(cwd),
               fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue,
               fm.isWritableFile(atPath: cwd) {
                return Self.normalize(URL(fileURLWithPath: cwd)
                    .appendingPathComponent(Self.folderName))
            }
        }
        if central {
            return Self.normalize(Paths.mirror.appendingPathComponent(fallbackNames[cwd] ?? "Unknown"))
        }
        // The working directory is gone; keep the session reachable anyway.
        return Self.normalize(Paths.mirror
            .appendingPathComponent("_Unavailable")
            .appendingPathComponent(fallbackNames[cwd] ?? "Unknown"))
    }

    /// Folder name per distinct cwd, used only for the central mirror. Two projects
    /// sharing a basename get disambiguated by their parent rather than merged.
    private func fallbackFolderNames(for sessions: [Session]) -> [String: String] {
        let cwds = Set(sessions.map(\.cwd))
        var byBase: [String: [String]] = [:]
        for cwd in cwds {
            let base = cwd.isEmpty ? "Unknown" : (cwd as NSString).lastPathComponent
            byBase[base, default: []].append(cwd)
        }
        var out: [String: String] = [:]
        for (base, list) in byBase {
            if list.count == 1 {
                out[list[0]] = Self.sanitize(base)
            } else {
                for cwd in list {
                    let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    out[cwd] = Self.sanitize(parent.isEmpty ? base : "\(parent) – \(base)")
                }
            }
        }
        return out
    }

    // MARK: - Per-folder extras

    /// Drops two helpers into every folder we wrote to:
    ///   .ccf-project                — the real cwd, so "New Session Here" knows where to open
    ///   + New Session.claudesession — double-click to start a session in that folder
    ///
    /// Also keeps the files out of `git status` for working directories that are
    /// git repositories, by adding an entry to .git/info/exclude — which is local
    /// to the clone and never committed.
    private func writeFolderExtras(roots: Set<URL>, sessions: [Session],
                                   fallbackNames: [String: String]) throws {
        var cwdByRoot: [URL: String] = [:]
        for s in sessions where !s.cwd.isEmpty {
            cwdByRoot[mainRoot(cwd: s.cwd, fallbackNames: fallbackNames)] = s.cwd
        }

        for dir in Set(roots.map { $0.lastPathComponent == Self.archiveFolderName
                                   ? $0.deletingLastPathComponent() : $0 }) {
            guard fm.fileExists(atPath: dir.path) else { continue }
            guard let cwd = cwdByRoot[dir], !cwd.isEmpty else { continue }

            let marker = dir.appendingPathComponent(".ccf-project")
            if (try? String(contentsOf: marker, encoding: .utf8)) != cwd {
                try? cwd.write(to: marker, atomically: true, encoding: .utf8)
            }

            let opener = dir.appendingPathComponent("+ New Session.claudesession")
            let html = Self.newSessionHTML(cwd: cwd)
            if (try? String(contentsOf: opener, encoding: .utf8)) != html {
                try? write(html, to: opener)
            }

            if gitExclude, dir.deletingLastPathComponent().path == cwd {
                addGitExclude(repo: URL(fileURLWithPath: cwd))
            }
        }
    }

    /// Appends the mirror folder to .git/info/exclude. That file is per-clone and
    /// untracked, so this never shows up in anyone's diff.
    private func addGitExclude(repo: URL) {
        let gitDir = repo.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue else { return }

        let info = gitDir.appendingPathComponent("info")
        let exclude = info.appendingPathComponent("exclude")
        let rule = "\(Self.folderName)/"

        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == rule })
        else { return }

        try? fm.createDirectory(at: info, withIntermediateDirectories: true)
        let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
            + "\n# added by ccfinder — mirrored Claude Code sessions\n\(rule)\n"
        try? (existing + addition).write(to: exclude, atomically: true, encoding: .utf8)
        log("git exclude: \(repo.path)")
    }

    static func newSessionHTML(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="claude-action" content="new">
        <meta name="claude-cwd" content="\(Render.esc(cwd))">
        <title>New session in \(Render.esc(name))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin:0; height:100vh; display:flex; flex-direction:column;
               align-items:center; justify-content:center; gap:10px;
               font: 15px/1.5 -apple-system, "PingFang TC", sans-serif; }
        .plus { font-size:44px; color:#c96442; }
        .sub { color:#6e6e73; font-size:13px; }
        </style>
        </head>
        <body>
          <div class="plus">+</div>
          <div>New Claude Code session in <strong>\(Render.esc(name))</strong></div>
          <div class="sub">double-click this file</div>
        </body>
        </html>
        """
    }

    // MARK: - Orphan recovery

    /// Treats dragging a session in or out of the Archive folder as an
    /// instruction to archive or unarchive it.
    ///
    /// A tracked file sitting somewhere other than where the index left it can
    /// only have been moved by the user. When the move crossed the Archive
    /// boundary we take it as intent and update Claude's record; the reconcile
    /// that follows then agrees with where the file already is, so nothing moves
    /// back and forth. Moves that do not cross that boundary are ignored, and the
    /// file is returned to its place by the normal pass.
    private func applyDragIntent(index: Index) {
        let found = scanMirror()

        for (id, entry) in index.entries {
            guard let current = found[id], current.path != entry.path else { continue }
            let was = Self.isInArchive(entry.path)
            let now = Self.isInArchive(current.path)
            guard was != now else { continue }

            do {
                try SessionStore.archive(desktopID: id, archived: now)
                log("\(now ? "archived" : "unarchived") by drag: \(current.lastPathComponent)")
            } catch {
                log("drag intent failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    static func isInArchive(_ path: String) -> Bool {
        (path as NSString).pathComponents.dropLast().last == archiveFolderName
    }

    /// Every mirrored file we can find, keyed by its desktop session id.
    private func scanMirror() -> [String: URL] {
        var out: [String: URL] = [:]
        for dir in candidateFolders() {
            guard let files = contents(of: dir) else { continue }
            for file in files where file.pathExtension == "claudesession" {
                let meta = SessionFile.meta(in: file)
                guard let id = meta["claude-desktop-id"], !id.isEmpty else { continue }
                out[id] = Self.normalize(file)
            }
        }
        return out
    }

    /// Directories that did not answer, remembered so they are only waited on once.
    ///
    /// A folder macOS protects — Desktop, Documents, iCloud Drive — does not fail
    /// for a background agent that has not been granted access: the `open` simply
    /// never returns, because it is waiting on a consent prompt that a launchd job
    /// has no way to show. `access()` is no help, since it reports the filesystem
    /// permission bits and knows nothing about that. So the only reliable defence
    /// is to put a clock on the call.
    private final class Blocklist: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        /// True for a blocked directory or anything beneath one, so a whole
        /// protected tree costs one timeout rather than one per folder.
        func contains(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if paths.contains(path) { return true }
            return paths.contains { path.hasPrefix($0 + "/") }
        }
        func insert(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.insert(path)
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return paths.sorted()
        }
    }
    private static let blocked = Blocklist()

    /// Folders that stopped responding this run.
    public static func blockedFolders() -> [String] { blocked.all }

    /// Lists a directory, giving up if it does not answer in time.
    ///
    /// The worker thread stays parked on the stuck `open` — there is no way to
    /// cancel it — but that costs one thread per bad folder, once, instead of the
    /// whole agent.
    func contents(of dir: URL, timeout: TimeInterval = 2) -> [URL]? {
        if Self.blocked.contains(dir.path) { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global(qos: .utility).async {
            box.value = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]
            )
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            let root = Self.highestBlockedAncestor(of: dir)
            Self.blocked.insert(root)
            Log.line("no access to \(root) — skipping it and everything under it")
            return nil
        }
        return box.value ?? []
    }

    private final class ResultBox: @unchecked Sendable { var value: [URL]? }

    /// Walks up from an unresponsive directory to find the top of the blocked
    /// tree — usually a folder macOS protects, like Desktop or Documents — so the
    /// whole subtree can be skipped after a single timeout.
    private static func highestBlockedAncestor(of dir: URL) -> String {
        let home = Paths.home.path
        var candidate = dir.path
        var probe = dir.deletingLastPathComponent().path

        while probe.hasPrefix(home), probe != home, probe.count > home.count {
            if respondsQuickly(probe) { break }
            candidate = probe
            probe = (probe as NSString).deletingLastPathComponent
        }
        return candidate
    }

    private static func respondsQuickly(_ path: String, timeout: TimeInterval = 1) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = try? FileManager.default.contentsOfDirectory(atPath: path)
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// Directories the watcher should follow so that dragging a file is noticed.
    public func watchPaths() -> [String] {
        var paths = [Paths.desktopSessions.path]
        let sessions = Discovery.sessions()
        let names = fallbackFolderNames(for: sessions)
        for cwd in Set(sessions.map(\.cwd)) {
            let root = mainRoot(cwd: cwd, fallbackNames: names)
            if contents(of: root) != nil { paths.append(root.path) }
        }
        if fm.fileExists(atPath: Paths.mirror.path) { paths.append(Paths.mirror.path) }
        return Array(Set(paths)).sorted()
    }

    /// Re-attaches mirror files whose index entry was lost — the state file is
    /// deleted on uninstall, and without this a reinstall would leave the old
    /// filename behind as an orphan the next time a session was retitled.
    /// Each file records its own desktop session id, so the index is rebuildable.
    private func adoptOrphans(into index: inout Index) {
        for (id, file) in scanMirror() {
            // A tracked file that moved is handled by applyDragIntent and the main
            // pass; only genuinely unknown ids need adopting here.
            guard index.entries[id] == nil else { continue }
            let meta = SessionFile.meta(in: file)
            // An empty hash guarantees the content is rewritten on this pass.
            index.entries[id] = Entry(path: file.path, title: meta["claude-title"] ?? "", hash: "")
        }
    }

    /// Every folder that could hold mirrored files: the per-project folders inside
    /// each known working directory, plus everything under the central mirror.
    private func candidateFolders() -> [URL] {
        var out: [URL] = []

        for cwd in Set(Discovery.sessions().map(\.cwd)) where !cwd.isEmpty {
            let dir = URL(fileURLWithPath: cwd).appendingPathComponent(Self.folderName)
            if fm.fileExists(atPath: dir.path) { out.append(dir) }
            let archive = dir.appendingPathComponent(Self.archiveFolderName)
            if fm.fileExists(atPath: archive.path) { out.append(archive) }
        }

        var stack = [Paths.mirror]
        while let dir = stack.popLast() {
            guard let children = contents(of: dir) else { continue }
            out.append(dir)
            for child in children {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    stack.append(child)
                }
            }
        }
        return out
    }

    // MARK: - Helpers

    private func write(_ s: String, to url: URL) throws {
        // Deliberately NOT atomic: an atomic write replaces the inode and would
        // drop the file's extended attributes, i.e. the user's Finder tags.
        try Data(s.utf8).write(to: url)
    }

    private func pruneEmptyParent(of url: URL) {
        var dir = url.deletingLastPathComponent()
        // Walk up at most twice: out of Archive, then out of the mirror folder.
        for _ in 0..<2 {
            let name = dir.lastPathComponent
            guard name == Self.folderName || name == Self.archiveFolderName
                    || dir.path.hasPrefix(Paths.mirror.path) else { return }
            guard dir.path != Paths.mirror.path else { return }

            let remaining = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .filter { $0 != ".ccf-project" && $0 != "+ New Session.claudesession" && $0 != ".DS_Store" }
            guard remaining?.isEmpty == true else { return }
            let parent = dir.deletingLastPathComponent()
            try? fm.removeItem(at: dir)
            dir = parent
        }
    }

    static func sanitize(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "/", with: "／")   // ":" and "/" are illegal in Finder names
            .replacingOccurrences(of: ":", with: "：")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" }
        return s.isEmpty ? "Untitled session" : s
    }

    /// `/var` and `/private/var` name the same directory. FileManager hands back
    /// the resolved form while a path read from JSON keeps the symlink, so without
    /// normalising, reconcile mistakes one for a rename of the other.
    static func normalize(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).resolvingSymlinksInPath).standardized
    }

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func loadIndex() -> Index {
        guard let data = try? Data(contentsOf: Paths.indexFile),
              var idx = try? JSONDecoder().decode(Index.self, from: data) else { return Index() }

        // v1 stored paths relative to the central mirror; v2 stores them absolute
        // because files now live in many different roots.
        if idx.version < 2 {
            for (id, entry) in idx.entries where !entry.path.hasPrefix("/") {
                var moved = entry
                moved.path = Paths.mirror.appendingPathComponent(entry.path).path
                idx.entries[id] = moved
            }
            idx.version = 2
        }
        return idx
    }

    private func saveIndex(_ index: Index) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(index).write(to: Paths.indexFile)
    }

    private func log(_ msg: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("\(msg)\n".utf8))
    }
}
