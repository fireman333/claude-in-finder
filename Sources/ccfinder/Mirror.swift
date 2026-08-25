import Foundation
import CCFKit
import CryptoKit

/// Reconciles ~/Claude Sessions/ against Claude Desktop's session index.
///
/// State is kept in index.json so that a retitled session becomes a *move* of
/// the existing file rather than a delete + create. That matters: moving keeps
/// the file's Finder tags, comments and any aliases the user made to it.
struct Mirror {

    struct Entry: Codable {
        var path: String      // relative to the mirror root
        var title: String
        var hash: String
    }

    struct Index: Codable {
        var version: Int = 1
        var entries: [String: Entry] = [:]   // keyed by desktop session id
    }

    var includeArchived: Bool
    var prune: Bool
    var verbose: Bool

    let fm = FileManager.default

    // MARK: - Entry point

    @discardableResult
    func reconcile() throws -> (created: Int, renamed: Int, updated: Int, removed: Int) {
        try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try fm.createDirectory(at: Paths.mirror, withIntermediateDirectories: true)

        var index = loadIndex()
        adoptOrphans(into: &index)
        let transcripts = Discovery.transcriptIndex()

        var sessions = Discovery.sessions()
        if !includeArchived { sessions.removeAll { $0.isArchived } }

        let folders = folderNames(for: sessions)
        var stats = (created: 0, renamed: 0, updated: 0, removed: 0)
        var live = Set<String>()
        var usedPaths = Set<String>()

        // Newest first so that, on a filename clash, the session you touched most
        // recently keeps the clean name and the older one gets the suffix.
        for session in sessions.sorted(by: { $0.sortDate > $1.sortDate }) {
            live.insert(session.desktopID)

            let folder = folders[session.cwd] ?? "Unknown"
            var name = Self.sanitize(session.title)
            var rel = "\(folder)/\(name).claudesession"
            if usedPaths.contains(rel) {
                name += " · \(String((session.cliSessionID ?? session.desktopID).prefix(6)))"
                rel = "\(folder)/\(name).claudesession"
            }
            usedPaths.insert(rel)

            let dest = Paths.mirror.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            let content = Render.html(for: session, transcript: transcripts[session.cliSessionID ?? ""])
            let hash = Self.digest(content)

            let previous = index.entries[session.desktopID]
            let oldURL = previous.map { Paths.mirror.appendingPathComponent($0.path) }

            // Retitled: move the existing file so Finder metadata survives.
            if let previous, let oldURL, previous.path != rel, fm.fileExists(atPath: oldURL.path) {
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: oldURL, to: dest)
                stats.renamed += 1
                log("renamed: \(previous.path) → \(rel)")
                pruneEmptyParent(of: oldURL)
            }

            let exists = fm.fileExists(atPath: dest.path)
            if !exists {
                try write(content, to: dest)
                stats.created += 1
                log("created: \(rel)")
            } else if previous?.hash != hash {
                try write(content, to: dest)
                stats.updated += 1
            }

            index.entries[session.desktopID] = Entry(path: rel, title: session.title, hash: hash)
        }

        // Remove mirror files for sessions that are gone. Only files we created and
        // still track are touched, so anything the user dropped in here is safe.
        if prune {
            for (id, entry) in index.entries where !live.contains(id) {
                let url = Paths.mirror.appendingPathComponent(entry.path)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                    pruneEmptyParent(of: url)
                    stats.removed += 1
                    log("removed: \(entry.path)")
                }
                index.entries.removeValue(forKey: id)
            }
        }

        try writeProjectMarkers(sessions: sessions, folders: folders)
        try saveIndex(index)
        return stats
    }

    /// Re-attaches mirror files whose index entry was lost — the state file is
    /// deleted on uninstall, and without this a reinstall would leave the old
    /// filename behind as an orphan the next time a session was retitled.
    /// Each file records its own desktop session id, so the index is rebuildable.
    private func adoptOrphans(into index: inout Index) {
        guard let projects = try? fm.contentsOfDirectory(
            at: Paths.mirror, includingPropertiesForKeys: nil
        ) else { return }

        var known = Set(index.entries.values.map(\.path))

        for dir in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }

            for file in files where file.pathExtension == "claudesession" {
                let rel = "\(dir.lastPathComponent)/\(file.lastPathComponent)"
                if known.contains(rel) { continue }

                let meta = SessionFile.meta(in: file)
                guard let id = meta["claude-desktop-id"], !id.isEmpty else { continue }

                // An empty hash guarantees the content is rewritten on this pass.
                index.entries[id] = Entry(path: rel, title: meta["claude-title"] ?? "", hash: "")
                known.insert(rel)
            }
        }
    }

    // MARK: - Per-project extras

    /// Drops two helpers into every project folder:
    ///   .ccf-project            — the real cwd, so "New Session Here" knows where to open
    ///   + New Session.claudesession — double-click to start a new session in that folder
    private func writeProjectMarkers(sessions: [Session], folders: [String: String]) throws {
        var cwdByFolder: [String: String] = [:]
        for s in sessions { if let f = folders[s.cwd] { cwdByFolder[f] = s.cwd } }

        for (folder, cwd) in cwdByFolder where !cwd.isEmpty {
            let dir = Paths.mirror.appendingPathComponent(folder)
            guard fm.fileExists(atPath: dir.path) else { continue }

            let marker = dir.appendingPathComponent(".ccf-project")
            try? cwd.write(to: marker, atomically: true, encoding: .utf8)

            let opener = dir.appendingPathComponent("+ New Session.claudesession")
            let html = Self.newSessionHTML(cwd: cwd)
            if (try? String(contentsOf: opener, encoding: .utf8)) != html {
                try? write(html, to: opener)
            }
        }
    }

    static func newSessionHTML(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return """
        <!doctype html>
        <html lang="zh-Hant">
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
          <div class="plus">＋</div>
          <div>在 <strong>\(Render.esc(name))</strong> 開新的 Claude Code 對話</div>
          <div class="sub">雙擊這個檔案</div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    private func write(_ s: String, to url: URL) throws {
        // Deliberately NOT atomic: an atomic write replaces the inode and would
        // drop the file's extended attributes, i.e. the user's Finder tags.
        try Data(s.utf8).write(to: url)
    }

    /// Folder name per distinct cwd. Two projects sharing a basename get
    /// disambiguated by their parent directory rather than silently merged.
    private func folderNames(for sessions: [Session]) -> [String: String] {
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

    private func pruneEmptyParent(of url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.path != Paths.mirror.path else { return }
        let remaining = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter { $0 != ".ccf-project" && $0 != "+ New Session.claudesession" && $0 != ".DS_Store" }
        if remaining?.isEmpty == true { try? fm.removeItem(at: dir) }
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

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func loadIndex() -> Index {
        guard let data = try? Data(contentsOf: Paths.indexFile),
              let idx = try? JSONDecoder().decode(Index.self, from: data) else { return Index() }
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
