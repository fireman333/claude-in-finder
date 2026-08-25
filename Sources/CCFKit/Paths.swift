import Foundation

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Claude Desktop's own per-session index: .../claude-code-sessions/<account>/<org>/local_<uuid>.json
    /// Override with CCF_SESSIONS (used by the test harness).
    public static var desktopSessions: URL {
        if let s = ProcessInfo.processInfo.environment["CCF_SESSIONS"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Claude Code CLI transcripts: ~/.claude/projects/<slug>/<cli-session-uuid>.jsonl
    public static let cliProjects = home.appendingPathComponent(".claude/projects")

    /// Where the Finder-visible mirror lives. Override with CCF_MIRROR.
    public static var mirror: URL {
        if let s = ProcessInfo.processInfo.environment["CCF_MIRROR"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Claude Sessions")
    }

    /// Override with CCF_SUPPORT so a test run never touches the real install's state.
    public static var support: URL {
        if let s = ProcessInfo.processInfo.environment["CCF_SUPPORT"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Application Support/ClaudeInFinder")
    }

    /// Override with CCF_INDEX so a test run never touches the real install's state.
    /// Every place a deleted file might have landed. Override with CCF_TRASH for
    /// tests. iCloud-synced folders use their own trash, not the home one.
    public static var trashLocations: [URL] {
        if let s = ProcessInfo.processInfo.environment["CCF_TRASH"], !s.isEmpty {
            return [URL(fileURLWithPath: (s as NSString).expandingTildeInPath)]
        }
        var out = [home.appendingPathComponent(".Trash")]
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/.Trash")
        if FileManager.default.fileExists(atPath: cloud.path) { out.append(cloud) }
        if let volumes = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
            for volume in volumes {
                let t = volume.appendingPathComponent(".Trashes/\(getuid())")
                if FileManager.default.fileExists(atPath: t.path) { out.append(t) }
            }
        }
        return out
    }

    public static var indexFile: URL {
        if let s = ProcessInfo.processInfo.environment["CCF_INDEX"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return support.appendingPathComponent("index.json")
    }
}
