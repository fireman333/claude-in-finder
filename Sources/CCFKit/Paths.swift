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

    public static let support = home
        .appendingPathComponent("Library/Application Support/ClaudeInFinder")

    /// Override with CCF_INDEX so a test run never touches the real install's state.
    public static var indexFile: URL {
        if let s = ProcessInfo.processInfo.environment["CCF_INDEX"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return support.appendingPathComponent("index.json")
    }
}
