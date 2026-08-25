import Foundation

/// Archives and deletes sessions by editing Claude Desktop's own session records.
///
/// Both operations follow the conventions Claude itself uses, read out of the app:
///   archive — flip `isArchived` in local_<uuid>.json
///   delete  — write a tombstone `deleted_<uuid>` holding the epoch-ms timestamp,
///             then remove local_<uuid>.json (Claude calls these SessionTombstones)
///
/// Deleting never touches the CLI transcript under ~/.claude/projects, and the
/// record is copied into our own folder first, so the conversation itself is
/// still on disk afterwards.
public enum SessionStore {

    public enum StoreError: LocalizedError {
        case notFound(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let id):   return "No Claude session record for \(id)."
            case .unreadable(let id): return "Could not read the session record for \(id)."
            }
        }
    }

    /// Backups of records removed by `delete`, so a mistaken click is recoverable.
    public static var backupDir: URL { Paths.support.appendingPathComponent("deleted") }

    /// Finds local_<uuid>.json for a desktop session id (with or without the prefix).
    public static func locate(desktopID: String) -> URL? {
        let uuid = bareUUID(desktopID)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: Paths.desktopSessions,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "local_\(uuid).json" {
            return url
        }
        return nil
    }

    public static func title(desktopID: String) -> String? {
        guard let url = locate(desktopID: desktopID),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["title"] as? String
    }

    @discardableResult
    public static func archive(desktopID: String, archived: Bool = true) throws -> URL {
        guard let url = locate(desktopID: desktopID) else { throw StoreError.notFound(desktopID) }
        guard let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw StoreError.unreadable(desktopID) }

        obj["isArchived"] = archived
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try out.write(to: url, options: .atomic)
        return url
    }

    /// Renames the session in Claude's own record.
    ///
    /// Marked as user-set, because that is what it is — otherwise Claude may
    /// replace it again with a title generated from the conversation.
    @discardableResult
    public static func rename(desktopID: String, to title: String) throws -> URL {
        guard let url = locate(desktopID: desktopID) else { throw StoreError.notFound(desktopID) }
        guard let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw StoreError.unreadable(desktopID) }

        obj["title"] = title
        obj["titleSource"] = "user"
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try out.write(to: url, options: .atomic)
        return url
    }

    public static func delete(desktopID: String) throws {
        guard let url = locate(desktopID: desktopID) else { throw StoreError.notFound(desktopID) }
        let fm = FileManager.default
        let uuid = bareUUID(desktopID)

        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let backup = backupDir.appendingPathComponent("local_\(uuid).json")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: url, to: backup)

        // Claude's own tombstone format: the file name carries the id, the body is
        // the deletion time in epoch milliseconds.
        let tombstone = url.deletingLastPathComponent().appendingPathComponent("deleted_\(uuid)")
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        try stamp.write(to: tombstone, atomically: true, encoding: .utf8)

        try fm.removeItem(at: url)
    }

    /// Moves a mirrored file into or out of its Archive folder immediately.
    ///
    /// The sync agent would get there on its own, but not for a few seconds, and
    /// in the meantime the file has vanished from where the user was looking. Doing
    /// the move here means the folder reflects the click at once; the agent's next
    /// pass simply agrees with what it finds.
    @discardableResult
    public static func moveMirrorFile(_ url: URL, intoArchive: Bool) -> URL? {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let inArchive = parent.lastPathComponent == archiveFolderName

        guard inArchive != intoArchive else { return url }

        let destDir = intoArchive
            ? parent.appendingPathComponent(archiveFolderName)
            : parent.deletingLastPathComponent()
        let dest = destDir.appendingPathComponent(url.lastPathComponent)

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Kept in step with Mirror.archiveFolderName.
    public static let archiveFolderName = "Archive"

    private static func bareUUID(_ id: String) -> String {
        id.hasPrefix("local_") ? String(id.dropFirst("local_".count)) : id
    }
}
