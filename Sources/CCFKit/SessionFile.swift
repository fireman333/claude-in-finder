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
        guard let text = TimeLimited.text(at: url) else { return [:] }
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

        // "+" is a legal character in a query, so URLComponents leaves it as it
        // found it — but a reader that treats the query as form data turns it
        // back into a space. A folder called "HFpEF+AF" then arrives as
        // "HFpEF AF", which is a real-looking path that does not exist, and the
        // session fails at the moment you send the first message with "this
        // session's working folder no longer exists".
        //
        // Everything else that matters here — "&", "=", "#", spaces, non-ASCII —
        // URLComponents already encodes, so any "+" left in the encoded query
        // came from the path and means a literal plus.
        if let query = c.percentEncodedQuery, query.contains("+") {
            c.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        }
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

        // A marker records the real working directory. Walk up a couple of levels
        // so this works from inside the Archive subfolder too, and so folders under
        // the central mirror — whose names no longer resemble the path — resolve.
        var probe = dir
        for _ in 0..<3 {
            let marker = (probe as NSString).appendingPathComponent(".ccf-project")
            if let raw = TimeLimited.text(at: URL(fileURLWithPath: marker)) {
                let real = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                var realIsDir: ObjCBool = false
                if !real.isEmpty, fm.fileExists(atPath: real, isDirectory: &realIsDir), realIsDir.boolValue {
                    return real
                }
            }
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe || parent.isEmpty { break }
            probe = parent
        }

        // No usable marker: cut the path at the mirror folder, which covers a
        // freshly created folder we have not synced into yet.
        var components = (dir as NSString).pathComponents
        if let idx = components.lastIndex(of: mirrorFolderName), idx > 0 {
            components = Array(components[0..<idx])
            let candidate = NSString.path(withComponents: components)
            var candidateIsDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &candidateIsDir), candidateIsDir.boolValue {
                return candidate
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
