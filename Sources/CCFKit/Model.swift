import Foundation

// MARK: - Tolerant JSON access
//
// Claude Desktop writes these files itself and the value types are not guaranteed
// (isArchived has been seen as both Bool and String; timestamps as both Number and
// String). Read everything through these coercions rather than Codable.

struct JSONBag {
    let raw: [String: Any]

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        self.raw = dict
    }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case let v as String: return v.isEmpty ? nil : v
        case let v as NSNumber: return v.stringValue
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool {
        switch raw[key] {
        case let v as Bool: return v
        case let v as NSNumber: return v.boolValue
        case let v as String: return ["true", "yes", "1"].contains(v.lowercased())
        default: return false
        }
    }

    /// Claude stores these as epoch milliseconds, sometimes stringified.
    func date(_ key: String) -> Date? {
        let ms: Double?
        switch raw[key] {
        case let v as NSNumber: ms = v.doubleValue
        case let v as String: ms = Double(v)
        default: ms = nil
        }
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    func strings(_ key: String) -> [String] {
        (raw[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

// MARK: - Session

public struct Session {
    let desktopID: String        // "local_<uuid>"
    let cliSessionID: String?    // the UUID accepted by claude://resume?session=
    let bridgeIDs: [String]
    let cwd: String
    let title: String
    let titleSource: String?     // "user" | "auto" | nil
    public let isArchived: Bool
    let createdAt: Date?
    let lastActivityAt: Date?
    let model: String?

    /// Only sessions with a cliSessionID can be reopened via the resume deep link.
    var resumeURL: URL? {
        guard let cliSessionID else { return nil }
        return URL(string: "claude://resume?session=\(cliSessionID)")
    }

    var sortDate: Date { lastActivityAt ?? createdAt ?? .distantPast }

    init?(url: URL) {
        guard let bag = JSONBag(url: url) else { return nil }
        guard let sid = bag.string("sessionId") else { return nil }
        desktopID = sid
        cliSessionID = bag.string("cliSessionId")
        bridgeIDs = bag.strings("bridgeSessionIds")
        cwd = bag.string("cwd") ?? bag.string("originCwd") ?? ""
        title = bag.string("title") ?? "Untitled session"
        titleSource = bag.string("titleSource")
        isArchived = bag.bool("isArchived")
        createdAt = bag.date("createdAt")
        lastActivityAt = bag.date("lastActivityAt")
        model = bag.string("model")
    }
}

// MARK: - Discovery

public enum Discovery {
    /// All non-deleted desktop session records.
    public static func sessions() -> [Session] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: Paths.desktopSessions,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Session] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            // Desktop marks removed sessions with a "deleted_" prefix and no .json suffix.
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            if let s = Session(url: url) { out.append(s) }
        }
        return out
    }

    /// cliSessionID -> transcript .jsonl. Built by scanning rather than by
    /// recomputing Claude's project-dir slug, which is lossy and undocumented.
    static func transcriptIndex() -> [String: URL] {
        let fm = FileManager.default
        var map: [String: URL] = [:]
        guard let projects = try? fm.contentsOfDirectory(
            at: Paths.cliProjects, includingPropertiesForKeys: nil
        ) else { return map }

        for dir in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                map[f.deletingPathExtension().lastPathComponent] = f
            }
        }
        return map
    }
}
