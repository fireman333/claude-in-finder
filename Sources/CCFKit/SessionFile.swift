import Foundation
import AppKit

/// Reads a .claudesession file and turns it into the Claude deep link it stands for.
///
/// Two verified deep links are used (confirmed against Claude.app 1.34493.1):
///   claude://resume?session=<uuid>          resume an existing CLI session
///   claude://code/new?folder=<path>         start a new session in a folder
public enum SessionFile {

    /// Pulls `<meta name="..." content="...">` out of the file's head.
    public static func meta(in url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let head = String(text.prefix(4096))
        var out: [String: String] = [:]

        let pattern = #"<meta\s+name="([^"]+)"\s+content="([^"]*)">"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = head as NSString
        for m in re.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 2))
            out[key] = decodeEntities(value)
        }
        return out
    }

    public static func deepLink(for url: URL) -> URL? {
        let m = meta(in: url)

        if let session = m["claude-session"], !session.isEmpty {
            return resumeLink(sessionID: session)
        }
        if m["claude-action"] == "new", let cwd = m["claude-cwd"], !cwd.isEmpty {
            return newSessionLink(cwd: cwd)
        }
        return nil
    }

    /// Claude only accepts a bare lowercase-or-uppercase UUID here; anything else
    /// is rejected by the app with no visible error, so reject it early.
    public static func resumeLink(sessionID: String) -> URL? {
        let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return URL(string: "claude://resume?session=\(sessionID)")
    }

    public static func newSessionLink(cwd: String) -> URL? {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/new"
        c.queryItems = [URLQueryItem(name: "folder", value: cwd)]
        return c.url
    }

    /// Resolves whatever the user pointed at into the directory a new session
    /// should actually run in.
    ///
    /// The mirror folder sits *inside* the working directory, so asking for a new
    /// session from within it must walk back up — otherwise you would get a session
    /// rooted at "<project>/Claude Sessions" and, in turn, a nested mirror folder.
    public static func workingDirectory(for path: String) -> String {
        let fm = FileManager.default
        var dir = (path as NSString).expandingTildeInPath

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir), !isDir.boolValue {
            dir = (dir as NSString).deletingLastPathComponent
        }

        // The marker records the real working directory, including for folders
        // under the central mirror whose name no longer resembles the path.
        let marker = (dir as NSString).appendingPathComponent(".ccf-project")
        if let raw = try? String(contentsOfFile: marker, encoding: .utf8) {
            let real = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var realIsDir: ObjCBool = false
            if !real.isEmpty, fm.fileExists(atPath: real, isDirectory: &realIsDir), realIsDir.boolValue {
                return real
            }
        }

        // No marker yet (a folder we have not synced into): fall back to the name.
        if (dir as NSString).lastPathComponent == mirrorFolderName {
            let parent = (dir as NSString).deletingLastPathComponent
            var parentIsDir: ObjCBool = false
            if fm.fileExists(atPath: parent, isDirectory: &parentIsDir), parentIsDir.boolValue {
                return parent
            }
        }

        return dir
    }

    /// Kept in sync with Mirror.folderName.
    public static let mirrorFolderName = "Claude Sessions"

    @discardableResult
    public static func launch(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(url, configuration: config) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&amp;", with: "&")
    }
}
