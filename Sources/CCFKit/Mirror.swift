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
        /// A rename made in Finder that Claude has not accepted yet.
        var pendingTitle: String?
        var pendingAttempts: Int?
        /// The inputs the rendered HTML is made of. Unchanged means last pass's
        /// `hash` still stands and the transcript need not be read again.
        var fingerprint: String?
    }

    struct Index: Codable {
        var version: Int = 2
        var entries: [String: Entry] = [:]   // keyed by desktop session id
        /// Folders where the user deleted the "+ New Session" file. Putting it
        /// back there would be arguing with them.
        var noNewSessionFile: [String] = []
        /// Folders we have written it to, so a later absence is a deletion rather
        /// than a folder we simply have not reached yet.
        var newSessionFolders: [String] = []
        /// What the setting was on the previous pass, so switching it back on can
        /// be told apart from steady state and undo the per-folder suppressions.
        var newSessionFileEnabled: Bool?
    }

    /// What a pass did, and what the watcher needs to know about it.
    public struct Outcome {
        public var created = 0
        public var renamed = 0
        public var updated = 0
        public var removed = 0
        /// The folders to follow, worked out from the sessions this pass already
        /// read rather than by going back to disk for them again.
        public var watchPaths: [String] = []
        /// Every file this pass wrote. Stamping a file is a write in a watched
        /// folder, so a pass hands itself an FSEvent and answers it with another
        /// pass that can only ever find nothing; these are how the watcher tells
        /// its own handiwork from something the user did.
        public var selfWrites: Set<String> = []
    }

    /// Collects the paths a pass writes, across the several places that write them.
    final class WriteLog {
        private(set) var paths: Set<String> = []
        /// The folder counts too: writing a file into one is a change to the
        /// folder, and that arrives as its own event.
        func add(_ url: URL) {
            paths.insert(Mirror.normalize(url).path)
            paths.insert(Mirror.normalize(url.deletingLastPathComponent()).path)
        }
    }

    /// Leave archived sessions out of the mirror entirely (command line only).
    public var skipArchived: Bool
    public var prune: Bool
    public var verbose: Bool
    /// Put everything under the central mirror instead of inside working directories.
    public var central: Bool = false
    /// Add "Claude Sessions/" to .git/info/exclude so the files stay out of git status.
    public var gitExclude: Bool = true
    /// Whether the Archive folder is shown in Finder; hiding it keeps the files.
    public var showArchive: Bool = true
    /// What a session file disappearing from Finder should mean.
    public var onFinderDelete: Config.DeleteAction = .archive
    /// Whether folders get a "+ New Session" file at all.
    public var showNewSessionFile: Bool = true

    let fm = FileManager.default
    /// A whole-file lock held for the duration of a reconcile.
    private final class ReconcileLock {
        private var fd: Int32 = -1

        func acquire() {
            let path = Paths.support.appendingPathComponent("reconcile.lock").path
            fd = open(path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { return }
            flock(fd, LOCK_EX)
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    /// Scanned at most once per reconcile.
    private let trashBox = TrashBox()
    private final class TrashBox: @unchecked Sendable { var ids: Set<String>? }
    private var trashCache: Set<String>? {
        get { trashBox.ids }
        nonmutating set { trashBox.ids = newValue }
    }

    public init(skipArchived: Bool, prune: Bool, verbose: Bool,
                central: Bool = false, gitExclude: Bool = true,
                showArchive: Bool = true,
                onFinderDelete: Config.DeleteAction = .archive,
                showNewSessionFile: Bool = true) {
        self.skipArchived = skipArchived
        self.prune = prune
        self.verbose = verbose
        self.central = central
        self.gitExclude = gitExclude
        self.showArchive = showArchive
        self.onFinderDelete = onFinderDelete
        self.showNewSessionFile = showNewSessionFile
    }

    /// Builds a mirror from the saved settings, with optional per-run overrides.
    public static func fromConfig(forceCentral: Bool = false,
                                  forceSkipArchived: Bool = false,
                                  prune: Bool = true,
                                  gitExclude: Bool = true,
                                  verbose: Bool = false) -> Mirror {
        let config = Config.load()
        return Mirror(
            skipArchived: forceSkipArchived,
            prune: prune,
            verbose: verbose,
            central: forceCentral || config.layout == .central,
            gitExclude: gitExclude,
            showArchive: config.showArchive,
            onFinderDelete: config.onFinderDelete,
            showNewSessionFile: config.newSessionFile
        )
    }

    // MARK: - Entry point

    @discardableResult
    public func reconcile() throws -> Outcome {
        try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)

        // Only one reconcile at a time, across every process. Two of them running
        // together — the agent and a settings change, say — each see files the
        // other is midway through moving, and "missing" is exactly what this pass
        // reads as "the user deleted it".
        let lock = ReconcileLock()
        lock.acquire()
        defer { lock.release() }

        trashCache = nil
        var index = loadIndex()
        var sessions = Discovery.sessions()
        applyUserIntent(index: index, sessions: sessions)

        // Intent may have changed archive flags or removed records; re-read so the
        // pass below works from what Claude's records now actually say.
        sessions = Discovery.sessions()
        if skipArchived { sessions.removeAll { $0.isArchived } }

        // One scan of the mirror serves both of the readers below. Nothing
        // between here and the main loop moves a file — `adoptOrphans` only writes
        // to the index — and reading every mirrored file to find out whose it is
        // was the single most expensive thing a pass did.
        let scan = scanMirrorDetailed(sessions: sessions)
        adoptOrphans(into: &index, found: scan.found)
        let transcripts = Discovery.transcriptIndex()

        let fallbackNames = fallbackFolderNames(for: sessions)
        var out = Outcome()
        let writes = WriteLog()
        var live = Set<String>()
        var usedPaths = Set<String>()
        var roots = Set<URL>()

        // Newest first so that, on a filename clash, the session you touched most
        // recently keeps the clean name and the older one gets the suffix.
        // `scan` is frozen: it is the disk as the user left it, and the only
        // thing a rename in Finder can be read from. `locations` tracks where the
        // files are as this pass shuffles them, which is a different question.
        var locations = scan.found
        // Only a session this pass will reach can collect a file we set aside
        // for it. Anything else would be parked and left hidden indefinitely.
        let processing = Set(sessions.map(\.desktopID))
        var deleted = Set<String>()

        for var session in sessions.sorted(by: { $0.sortDate > $1.sortDate }) {
            // Did the user throw this session's file away? Decide it here rather
            // than in an earlier pass: a file deleted while that pass was running
            // is still present when it looks, and gets quietly recreated below —
            // after which it never looks deleted again.
            if let previous = index.entries[session.desktopID],
               vanished(entry: previous, id: session.desktopID, scan: scan) {
                switch effectiveDeleteAction(for: session.desktopID,
                                             wasIn: previous.path,
                                             scan: scan) {
                case .archive:
                    if !session.isArchived {
                        try? SessionStore.archive(desktopID: session.desktopID, archived: true)
                        session.isArchived = true
                        // Always logged, verbose or not: this changes Claude's data.
                        Log.line("archived (file deleted in Finder): \(session.title)")
                    }
                case .delete:
                    try? SessionStore.delete(desktopID: session.desktopID)
                    Log.line("deleted (file deleted in Finder): \(session.title)")
                    deleted.insert(session.desktopID)
                    index.entries.removeValue(forKey: session.desktopID)
                    continue
                }
            }

            // Renamed in Finder? Then the file is the instruction, not the record.
            // Only a rename in place counts: a move to another folder is either the
            // Archive gesture or something to be undone, both handled elsewhere.
            if let previous = index.entries[session.desktopID],
               let current = scan.found[session.desktopID],
               current.path != previous.path,
               current.deletingLastPathComponent().path
                   == URL(fileURLWithPath: previous.path).deletingLastPathComponent().path {
                let renamed = current.deletingPathExtension().lastPathComponent
                // Two names here are ours, not the user's, and writing either back
                // as the session's title is how the mirror used to end up arguing
                // with itself: the " · abc123" that separates two sessions wanting
                // one name, and the file a pass that died mid-swap left parked.
                // Skip only the write-back — the session still needs the rest of
                // this pass, which is what puts a parked file back.
                if !renamed.isEmpty, !renamed.hasPrefix(Self.parkingPrefix),
                   Self.withoutDisambiguator(renamed, for: session) != Self.sanitize(session.title) {
                    try? SessionStore.rename(desktopID: session.desktopID, to: renamed)
                    session.title = renamed
                    index.entries[session.desktopID]?.path = current.path
                    index.entries[session.desktopID]?.pendingTitle = renamed
                    index.entries[session.desktopID]?.pendingAttempts = 0
                    Log.line("renamed in Finder: \(previous.title) → \(renamed)")
                }
            }

            // Claude keeps the session it currently has open in memory and writes
            // its own title back over ours. Rather than let the file flap between
            // the two names, keep the name the user typed and keep re-applying it;
            // it takes hold as soon as Claude lets go of the session.
            if let pending = index.entries[session.desktopID]?.pendingTitle {
                if session.title == pending {
                    index.entries[session.desktopID]?.pendingTitle = nil
                    index.entries[session.desktopID]?.pendingAttempts = nil
                } else {
                    let attempts = (index.entries[session.desktopID]?.pendingAttempts ?? 0) + 1
                    if attempts > 60 {
                        index.entries[session.desktopID]?.pendingTitle = nil
                        index.entries[session.desktopID]?.pendingAttempts = nil
                        Log.line("giving up on renaming to \(pending); Claude keeps rewriting it")
                    } else {
                        index.entries[session.desktopID]?.pendingAttempts = attempts
                        try? SessionStore.rename(desktopID: session.desktopID, to: pending)
                        session.title = pending
                    }
                }
            }

            live.insert(session.desktopID)

            let root = self.root(for: session, fallbackNames: fallbackNames)
            var name = Self.sanitize(session.title)
            var dest = root.appendingPathComponent("\(name).claudesession")
            if usedPaths.contains(dest.path) {
                name = Self.disambiguated(name, for: session, avoiding: usedPaths, in: root)
                dest = root.appendingPathComponent("\(name).claudesession")
            }
            usedPaths.insert(dest.path)

            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            roots.insert(root)

            let transcript = transcripts[session.cliSessionID ?? ""]
            let fingerprint = Self.fingerprint(session: session, transcript: transcript)

            let previous = index.entries[session.desktopID]
            // Where this session's file actually is, according to the file itself.
            // The index is a step behind whenever two sessions trade names within
            // one pass, and following it then moves somebody else's file.
            let oldURL = locations[session.desktopID]
                ?? previous.map { URL(fileURLWithPath: $0.path) }

            // Rendering a session means reading and parsing its entire transcript,
            // and with hundreds of sessions on disk that is very nearly the whole
            // cost of a pass. The HTML is a function of the fingerprint's fields and
            // the transcript's bytes and nothing else, so while the fingerprint
            // matches, last pass's hash stands and not a byte has to be read.
            var rendered: String?
            // A preview built from a transcript we could not read must not be
            // remembered, or the empty one is served until the file's size or date
            // happens to change.
            var complete = true
            func content() -> String {
                if let rendered { return rendered }
                // Drain per session too: one transcript's worth of parsing should
                // not still be resident while the next nine hundred are read.
                let r = autoreleasepool { Render.render(for: session, transcript: transcript) }
                rendered = r.html
                complete = r.complete
                return r.html
            }
            let reusable = previous?.fingerprint == fingerprint && !(previous?.hash ?? "").isEmpty
            let hash = reusable ? (previous?.hash ?? "") : Self.digest(content())

            // Retitled, or the layout changed under it: move the existing file so
            // Finder metadata survives.
            if let oldURL, Self.normalize(oldURL).path != Self.normalize(dest).path,
               fm.fileExists(atPath: oldURL.path) {
                // Something is already standing where this one goes. Two sessions
                // sharing a transcript swap names the moment the older one is used
                // again, and deleting whatever is in the way then destroys a file
                // that was only passing through. Park it instead: its own turn in
                // this pass will collect it from where we left it.
                var clear = !fm.fileExists(atPath: dest.path)
                if !clear {
                    let occupant = locations.first {
                        $0.key != session.desktopID
                            && Self.normalize($0.value).path == Self.normalize(dest).path
                    }
                    if let occupant {
                        // Only a session this pass will reach can collect a file we
                        // set aside for it. One it will not reach is left exactly
                        // where it is and waited on — it is somebody's conversation,
                        // and `--no-prune` promises never to delete a mirrored file.
                        if processing.contains(occupant.key),
                           let parked = Self.freeParkingPath(for: occupant.key,
                                                             in: dest.deletingLastPathComponent()),
                           (try? fm.moveItem(at: dest, to: parked)) != nil {
                            locations[occupant.key] = Self.normalize(parked)
                            clear = true
                        }
                    } else {
                        // No session claims this file: a leftover, or one whose head
                        // we could not read. Nothing tracks it, so nothing loses it.
                        try? fm.removeItem(at: dest)
                        clear = !fm.fileExists(atPath: dest.path)
                    }
                }
                // Could not clear the way. Leave this session alone entirely and
                // try again next pass — falling through would write its page over
                // the occupant's file and stamp our id on their conversation,
                // which is the very thing parking exists to avoid. The file keeps
                // the name it has; the index still points at it; nothing is lost.
                guard clear else {
                    log("\(dest.lastPathComponent) is occupied; leaving \(oldURL.lastPathComponent) alone")
                    continue
                }
                do {
                    try fm.moveItem(at: oldURL, to: dest)
                    out.renamed += 1
                    log("moved: \(oldURL.path) → \(dest.path)")
                    pruneEmptyParent(of: oldURL)
                } catch {
                    // Fall through and write a fresh file; a single stubborn path
                    // should not take the rest of the sync down with it. `dest` was
                    // clear, so nothing of anyone else's is at stake.
                    log("move failed (\(error.localizedDescription)); rewriting instead")
                }
            }
            locations[session.desktopID] = Self.normalize(dest)

            // What the file on disk actually holds, which is not the same as what
            // this pass rendered — see the incomplete case below.
            // Empty means unknown, the same as an adopted orphan: whatever is
            // there was not written by this pass, so the next one rewrites it.
            var onDisk = previous?.hash ?? ""
            if !fm.fileExists(atPath: dest.path) {
                try write(content(), to: dest, log: writes)
                onDisk = hash
                out.created += 1
                log("created: \(dest.path)")
            } else if previous?.hash != hash, complete {
                // Only when the transcript was read. A preview already sitting there
                // is better than the empty page an unreadable transcript renders to;
                // the fingerprint is left unset, so the next pass tries again.
                try write(content(), to: dest, log: writes)
                onDisk = hash
                out.updated += 1
            }

            stamp(dest, with: session, log: writes)
            // Carry the pending rename forward. Rebuilding the entry from scratch
            // dropped it every pass, so `pendingAttempts` never reached the limit
            // that is meant to call off a rename Claude keeps overwriting.
            index.entries[session.desktopID] = Entry(
                path: dest.path, title: session.title, hash: onDisk,
                pendingTitle: index.entries[session.desktopID]?.pendingTitle,
                pendingAttempts: index.entries[session.desktopID]?.pendingAttempts,
                fingerprint: complete ? fingerprint : nil
            )
        }

        // Remove mirror files for sessions that are gone. Only files we created and
        // still track are touched, so anything the user dropped in here is safe.
        if prune {
            for (id, entry) in index.entries where !live.contains(id) {
                let url = URL(fileURLWithPath: entry.path)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                    pruneEmptyParent(of: url)
                    out.removed += 1
                    log("removed: \(entry.path)")
                }
                index.entries.removeValue(forKey: id)
            }
        }

        // A "+ New Session" file the user threw away is not put back. A folder we
        // have never written to is not the same thing as one they emptied, hence
        // the record of where it has been placed.
        var suppressed = Set(index.noNewSessionFile)
        var placed = Set(index.newSessionFolders)

        // Switching the setting back on is a request for all of them, including in
        // folders where one was deleted individually.
        if showNewSessionFile, index.newSessionFileEnabled == false {
            suppressed.removeAll()
            placed.removeAll()   // nothing to compare against; this pass re-places
        }
        index.newSessionFileEnabled = showNewSessionFile

        if showNewSessionFile {
            for dir in roots where scan.listed.contains(dir.path) && placed.contains(dir.path) {
                let opener = dir.appendingPathComponent("+ New Session.claudesession")
                if !fm.fileExists(atPath: opener.path), !suppressed.contains(dir.path) {
                    suppressed.insert(dir.path)
                    Log.line("leaving \(dir.lastPathComponent) without a + New Session file, as deleted")
                }
            }
        } else {
            for dir in roots {
                let opener = dir.appendingPathComponent("+ New Session.claudesession")
                try? fm.removeItem(at: opener)
            }
        }
        index.noNewSessionFile = suppressed.sorted()
        var placed2 = placed

        try writeFolderExtras(roots: roots, sessions: sessions, fallbackNames: fallbackNames, log: writes,
                              suppressedNewSession: showNewSessionFile ? suppressed : Set(roots.map(\.path)),
                              placedNewSession: &placed2)
        sweepEmptyArchives(roots: roots)
        applyArchiveVisibility(roots: roots)
        index.newSessionFolders = placed2.sorted()
        try saveIndex(index)
        out.watchPaths = watchPaths(sessions: sessions)
        out.selfWrites = writes.paths
        return out
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
                                   fallbackNames: [String: String], log: WriteLog,
                                   suppressedNewSession: Set<String>,
                                   placedNewSession: inout Set<String>) throws {
        // Keyed by path, not by URL: URL(fileURLWithPath:) stats the filesystem to
        // decide whether it is a directory, so the same folder is a different URL
        // before and after it is created — equal paths, unequal values, and a
        // lookup that silently misses.
        var cwdByRoot: [String: String] = [:]
        for s in sessions where !s.cwd.isEmpty {
            cwdByRoot[mainRoot(cwd: s.cwd, fallbackNames: fallbackNames).path] = s.cwd
        }

        for dir in Set(roots.map { $0.lastPathComponent == Self.archiveFolderName
                                   ? $0.deletingLastPathComponent() : $0 }) {
            guard fm.fileExists(atPath: dir.path) else { continue }
            guard let cwd = cwdByRoot[dir.path], !cwd.isEmpty else { continue }

            let marker = dir.appendingPathComponent(".ccf-project")
            if TimeLimited.text(at: marker) != cwd {
                try? cwd.write(to: marker, atomically: true, encoding: .utf8)
                log.add(marker)
            }

            let opener = dir.appendingPathComponent("+ New Session.claudesession")
            if suppressedNewSession.contains(dir.path) { continue }
            let html = Self.newSessionHTML(cwd: cwd)
            if TimeLimited.text(at: opener) != html {
                try? write(html, to: opener, log: log)
            }
            placedNewSession.insert(dir.path)

            if gitExclude, dir.deletingLastPathComponent().path == cwd {
                addGitExclude(repo: URL(fileURLWithPath: cwd))
            }
        }
    }

    /// Shows or hides the Archive folders.
    ///
    /// Hiding sets the folder's hidden flag rather than skipping the files, so the
    /// archived sessions are still there to be opened on demand — which is what
    /// "Open Archive Folder" in the right-click menu relies on.
    private func applyArchiveVisibility(roots: Set<URL>) {
        let mains = Set(roots.map {
            $0.lastPathComponent == Self.archiveFolderName ? $0.deletingLastPathComponent() : $0
        })
        for main in mains {
            let archive = main.appendingPathComponent(Self.archiveFolderName)
            guard fm.fileExists(atPath: archive.path) else { continue }
            var url = archive
            let current = (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
            guard current == showArchive else { continue }
            var values = URLResourceValues()
            values.isHidden = !showArchive
            try? url.setResourceValues(values)
        }
    }

    /// Removes Archive folders that no longer hold anything.
    ///
    /// pruneEmptyParent only fires for moves this pass performed, and unarchiving
    /// from the menu or by dragging moves the file before the sync ever sees it —
    /// leaving an empty Archive folder sitting there looking meaningful.
    private func sweepEmptyArchives(roots: Set<URL>) {
        let mains = Set(roots.map {
            $0.lastPathComponent == Self.archiveFolderName ? $0.deletingLastPathComponent() : $0
        })
        for main in mains {
            let archive = main.appendingPathComponent(Self.archiveFolderName)
            guard fm.fileExists(atPath: archive.path) else { continue }
            let remaining = (try? fm.contentsOfDirectory(atPath: archive.path))?
                .filter { $0 != ".DS_Store" }
            if remaining?.isEmpty == true { try? fm.removeItem(at: archive) }
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

        // A read can block indefinitely — this file may be an iCloud placeholder —
        // so treat "did not answer" as "leave this repository alone".
        guard let existing = TimeLimited.run(2, { (try? String(contentsOf: exclude, encoding: .utf8)) ?? "" })
        else {
            Log.line("skipping .git/info/exclude in \(repo.path) — it did not respond")
            return
        }
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
    private func applyUserIntent(index: Index, sessions: [Session]) {
        let found = scanMirror(sessions: sessions)

        for (id, entry) in index.entries {
            guard let current = found[id], current.path != entry.path else { continue }
            let was = Self.isInArchive(entry.path)
            let now = Self.isInArchive(current.path)
            guard was != now else { continue }

            do {
                try SessionStore.archive(desktopID: id, archived: now)
                Log.line("\(now ? "archived" : "unarchived") by drag: \(current.lastPathComponent)")
            } catch {
                log("drag intent failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    static func isInArchive(_ path: String) -> Bool {
        (path as NSString).pathComponents.dropLast().last == archiveFolderName
    }

    /// True when a session's mirrored file is no longer anywhere we look.
    ///
    /// Requires the folder it lived in to have answered this pass: a folder macOS
    /// refused to let us read also looks empty, and treating that as "every session
    /// in it was deleted" would be a disaster.
    private func vanished(entry: Entry, id: String,
                          scan: (found: [String: URL], listed: Set<String>)) -> Bool {
        guard scan.found[id] == nil else { return false }
        guard !fm.fileExists(atPath: entry.path) else { return false }
        let parent = Self.normalize(URL(fileURLWithPath: entry.path).deletingLastPathComponent()).path
        return scan.listed.contains(parent)
    }

    /// What a session file disappearing should mean, given where it disappeared from.
    ///
    /// Deleting works in two stages, like the Trash itself: removing a session from
    /// its folder archives it, and removing it from Archive — where it has already
    /// been put aside once — deletes it. That second step is deliberate enough to
    /// take at face value.
    ///
    /// Elsewhere, deleting the session outright needs proof: the file actually in
    /// the Trash. Something that merely went missing might have been dragged
    /// somewhere we do not look. Archiving that is a nuisance you undo by dragging
    /// it back; deleting it is not, so an unconfirmed disappearance is downgraded.
    private func effectiveDeleteAction(for id: String, wasIn path: String,
                                       scan: (found: [String: URL], listed: Set<String>))
        -> Config.DeleteAction {
        if Self.isInArchive(path) { return .delete }
        guard onFinderDelete == .delete else { return .archive }
        if trashedSessionIDs().contains(id) { return .delete }
        log("\(id) is gone but not in the Trash — archiving instead of deleting")
        return .archive
    }

    /// Session ids whose mirror file is sitting in the Trash.
    private func trashedSessionIDs() -> Set<String> {
        if let cached = trashCache { return cached }
        var ids = Set<String>()
        for dir in Paths.trashLocations {
            guard let files = contents(of: dir) else { continue }
            for file in files where file.pathExtension == "claudesession" {
                if let id = SessionFile.meta(in: file)["claude-desktop-id"], !id.isEmpty {
                    ids.insert(id)
                }
            }
        }
        trashCache = ids
        return ids
    }

    /// Every mirrored file we can find, keyed by its desktop session id.
    private func scanMirror(sessions: [Session]) -> [String: URL] {
        scanMirrorDetailed(sessions: sessions).found
    }

    /// Also reports which folders answered, so a folder we could not read is never
    /// mistaken for a folder whose files were deleted.
    private func scanMirrorDetailed(sessions: [Session]) -> (found: [String: URL], listed: Set<String>) {
        var out: [String: URL] = [:]
        var listed = Set<String>()
        for dir in candidateFolders(sessions: sessions) {
            guard let files = contents(of: dir) else { continue }
            listed.insert(Self.normalize(dir).path)
            for file in files where file.pathExtension == "claudesession" {
                let meta = SessionFile.meta(in: file)
                guard let id = meta["claude-desktop-id"], !id.isEmpty else { continue }
                out[id] = Self.normalize(file)
            }
        }
        return (out, listed)
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

        let listed = TimeLimited.run(timeout) {
            try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]
            )
        }

        guard let contents = listed else {
            let root = Self.highestBlockedAncestor(of: dir)
            Self.blocked.insert(root)
            Log.line("no access to \(root) — skipping it and everything under it")
            return nil
        }
        return contents ?? []
    }

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
        TimeLimited.run(timeout) { _ = try? FileManager.default.contentsOfDirectory(atPath: path) } != nil
    }

    /// Directories the watcher should follow so that dragging a file is noticed.
    public func watchPaths() -> [String] { watchPaths(sessions: Discovery.sessions()) }

    /// The same, for a caller that has just read the sessions and need not pay
    /// for reading all of them a second time.
    public func watchPaths(sessions: [Session]) -> [String] {
        var paths = [Paths.desktopSessions.path]
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
    private func adoptOrphans(into index: inout Index, found: [String: URL]) {
        for (id, file) in found {
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
    private func candidateFolders(sessions: [Session]) -> [URL] {
        var out: [URL] = []

        for cwd in Set(sessions.map(\.cwd)) where !cwd.isEmpty {
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

    private func write(_ s: String, to url: URL, log: WriteLog? = nil) throws {
        log?.add(url)
        // Deliberately NOT atomic: an atomic write replaces the inode and would
        // drop the file's extended attributes, i.e. the user's Finder tags.
        try Data(s.utf8).write(to: url)
    }

    /// Gives the file the conversation's own dates.
    ///
    /// Without this, "Date Modified" in Finder is when the mirror last rewrote the
    /// file — which is roughly the same recent moment for everything, and makes
    /// sorting by date, the obvious way to find last week's session, meaningless.
    /// The file stands for the conversation, so it should carry its dates.
    ///
    /// Skipped when they already match. Writing attributes fires an FSEvent, and
    /// the watcher listening for it would sync again, stamp again, and never
    /// settle.
    private func stamp(_ url: URL, with session: Session, log: WriteLog? = nil) {
        guard let modified = session.lastActivityAt ?? session.createdAt else { return }
        let created = session.createdAt ?? modified

        let current = try? fm.attributesOfItem(atPath: url.path)
        func matches(_ attribute: FileAttributeKey, _ wanted: Date) -> Bool {
            guard let have = current?[attribute] as? Date else { return false }
            return abs(have.timeIntervalSince(wanted)) < 1
        }
        guard !(matches(.modificationDate, modified) && matches(.creationDate, created)) else { return }

        try? fm.setAttributes([.modificationDate: modified, .creationDate: created],
                              ofItemAtPath: url.path)
        log?.add(url)
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

    /// The suffix that separates two sessions wanting the same file name.
    ///
    /// It has to come from the *desktop* id. Two desktop sessions can share one
    /// CLI transcript, and keying off the CLI id then gave both of them the same
    /// "unique" suffix: each pass moved one file on top of the other, the survivor
    /// disagreed with the index about whose it was, and that read as a rename in
    /// Finder.
    private static func disambiguated(_ name: String, for session: Session,
                                      avoiding used: Set<String>, in root: URL) -> String {
        let stem = String(bareUUID(session.desktopID).prefix(6))
        var candidate = "\(name) · \(stem)"
        var n = 2
        while used.contains(root.appendingPathComponent("\(candidate).claudesession").path) {
            candidate = "\(name) · \(stem)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Prefix for a file set aside while two sessions trade names. Hidden, and
    /// recognisable, so a pass that dies mid-swap leaves something the next pass
    /// can put back rather than something it reads as a rename.
    static let parkingPrefix = ".ccf-moving-"

    /// A free name to set a file aside under while two sessions trade places.
    /// Never overwrites: a file already parked under this id is one a pass that
    /// died left behind, and it is still somebody's conversation. Returns nil if
    /// no name is free, which the caller reads as "leave everything alone".
    private static func freeParkingPath(for desktopID: String, in folder: URL) -> URL? {
        let fm = FileManager.default
        let stem = "\(parkingPrefix)\(bareUUID(desktopID))"
        for n in 1...50 {
            let name = n == 1 ? "\(stem).claudesession" : "\(stem)-\(n).claudesession"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Claude's own session ids are "local_<uuid>"; the uuid alone is what names
    /// things on our side.
    static func bareUUID(_ id: String) -> String {
        id.hasPrefix("local_") ? String(id.dropFirst("local_".count)) : id
    }

    /// Removes the suffix `disambiguated` would have given *this* session, so a
    /// name we chose is not mistaken for one the user typed.
    ///
    /// Matched against that one session's own stem rather than against the shape
    /// of a stem: digits are hex, so anything looser silently swallows a rename
    /// to something like "Sprint · 202601" and never tells Claude about it.
    private static func withoutDisambiguator(_ name: String, for session: Session) -> String {
        guard let sep = name.range(of: " · ", options: .backwards) else { return name }
        let tail = String(name[sep.upperBound...])
        let stem = String(bareUUID(session.desktopID).prefix(6))
        let numbered = tail.hasPrefix("\(stem)-")
            && tail.count > stem.count + 1
            && tail.dropFirst(stem.count + 1).allSatisfy(\.isNumber)
        guard tail == stem || numbered else { return name }
        return String(name[..<sep.lowerBound])
    }

    /// Everything `Render.html` reads, boiled down to one comparable string: the
    /// session fields that reach the page, plus the transcript's identity, size
    /// and modification date.
    private static func fingerprint(session: Session, transcript: URL?) -> String {
        var parts = [
            // What the renderer produces is an input too. Without this, a release
            // that changes the HTML or the stylesheet would leave every existing
            // preview as it was, for good: the fingerprint would still match and
            // the file would never be rewritten.
            AppVersion.current,
            session.desktopID,
            session.cliSessionID ?? "",
            session.title,
            session.cwd,
            session.model ?? "",
            session.lastActivityAt.map { String($0.timeIntervalSince1970) } ?? "",
        ]
        if let transcript {
            let attrs = try? FileManager.default.attributesOfItem(atPath: transcript.path)
            let size = (attrs?[.size] as? NSNumber)?.stringValue ?? "?"
            let mtime = (attrs?[.modificationDate] as? Date)
                .map { String($0.timeIntervalSince1970) } ?? "?"
            parts.append("\(transcript.path)|\(size)|\(mtime)")
        } else {
            parts.append("no transcript")
        }
        return digest(parts.joined(separator: "\u{1}"))
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
