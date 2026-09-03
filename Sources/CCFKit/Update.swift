import Foundation

/// The version this build reports.
///
/// Bumped by hand at release time, and read by `Scripts/build.sh` — so the app
/// bundle, the DMG name and the update check can never disagree about what is
/// installed, which is the one way an update reminder becomes a liar.
public enum AppVersion {
    public static let value = "0.12.2"

    /// Override with CCF_VERSION so a test run can pretend to be any version.
    public static var current: String {
        if let s = ProcessInfo.processInfo.environment["CCF_VERSION"], !s.isEmpty { return s }
        return value
    }
}

/// Looking up the latest GitHub release and remembering the answer.
///
/// It only ever *tells* you: nothing is downloaded and nothing is installed, so
/// there is no update mechanism to get wrong. The app is ad-hoc signed and every
/// install re-grants two permissions by hand, which is exactly the kind of thing
/// that should not happen behind your back.
public enum Update {

    public static let repo = "fireman333/claude-in-finder"

    /// How long between scheduled checks, and how soon to try again when one
    /// fails — a laptop that was shut when the day rolled over should not have
    /// to wait another one.
    public static let interval: TimeInterval = 24 * 60 * 60
    public static let retryInterval: TimeInterval = 60 * 60

    public struct Release: Codable, Equatable {
        /// Without the leading "v": "0.10.1".
        public var version: String
        /// The release page to send the user to.
        public var url: String
        /// The release title, when it has one.
        public var name: String?

        public init(version: String, url: String, name: String? = nil) {
            self.version = version
            self.url = url
            self.name = name
        }
    }

    public enum Outcome: Equatable {
        case upToDate(String)
        case available(Release)
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What the last check found, kept on disk so the menu bar can say "update
    /// available" without going to the network every time a menu opens.
    public struct State: Codable, Equatable {
        public var lastCheck: Date?
        /// Set when the last attempt failed, so the retry window applies.
        public var lastCheckFailed: Bool = false
        public var latest: Release?

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
            lastCheckFailed = try c.decodeIfPresent(Bool.self, forKey: .lastCheckFailed) ?? false
            latest = try c.decodeIfPresent(Release.self, forKey: .latest)
        }
    }

    public static var stateURL: URL { Paths.support.appendingPathComponent("update.json") }

    public static var releasesPage: URL {
        URL(string: "https://github.com/\(repo)/releases/latest")!
    }

    public static func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }

    static func save(_ state: State) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(state).write(to: stateURL)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The release worth telling the user about: the last one seen, if it is
    /// still newer than what is running. Reads a file, so it is safe to call
    /// while a menu is opening.
    public static var pending: Release? {
        guard let latest = loadState().latest,
              isNewer(latest.version, than: AppVersion.current) else { return nil }
        return latest
    }

    public static var isDue: Bool {
        let state = loadState()
        guard let last = state.lastCheck else { return true }
        let wait = state.lastCheckFailed ? retryInterval : interval
        // A clock that went backwards would otherwise park the check forever.
        return Date().timeIntervalSince(last) >= wait || last > Date()
    }

    /// The scheduled path. Returns nil when it did not look — the setting is off,
    /// or the last check was recent enough.
    @discardableResult
    public static func checkIfDue(config: Config = .load()) -> Outcome? {
        guard config.updateCheck, isDue else { return nil }
        return try? check()
    }

    /// Goes to the network. Throws rather than reporting "up to date" when it
    /// cannot tell: a check that fails quietly is worse than no check at all,
    /// because it looks like an answer.
    @discardableResult
    public static func check() throws -> Outcome {
        var state = loadState()
        do {
            let release = try fetchLatest()
            state.lastCheck = Date()
            state.lastCheckFailed = false
            state.latest = release
            save(state)
            return isNewer(release.version, than: AppVersion.current)
                ? .available(release)
                : .upToDate(AppVersion.current)
        } catch {
            state.lastCheck = Date()
            state.lastCheckFailed = true
            save(state)
            throw error
        }
    }

    // MARK: - GitHub

    /// Point CCF_UPDATE_API at a file to run the check against a fixture.
    static var apiURL: URL {
        if let s = ProcessInfo.processInfo.environment["CCF_UPDATE_API"], !s.isEmpty {
            if s.contains("://"), let url = URL(string: s) { return url }
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    static func fetchLatest() throws -> Release {
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub turns away requests that do not identify themselves.
        request.setValue("claude-in-finder/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        var payload: Data?
        var transportError: Error?
        var status = 200
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            transportError = error
            if let http = response as? HTTPURLResponse { status = http.statusCode }
            done.signal()
        }.resume()
        // The request has its own timeout; this is the backstop for the call that
        // never comes back at all, which must not park a menu bar app forever.
        guard done.wait(timeout: .now() + 30) == .success else {
            throw Failure(message: "the check timed out")
        }
        if let transportError { throw transportError }
        guard status == 200 else {
            throw Failure(message: status == 403
                ? "GitHub is rate-limiting this check (403)"
                : "GitHub answered \(status)")
        }
        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty
        else { throw Failure(message: "no release information in the reply") }

        let page = json["html_url"] as? String ?? releasesPage.absoluteString
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Release(version: normalised(tag), url: page, name: name)
    }

    // MARK: - Versions

    /// "v0.10.0" and "0.10.0" are the same thing; tags carry the v, the bundle
    /// does not.
    public static func normalised(_ version: String) -> String {
        var s = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// Numeric, component by component — 0.10.0 is newer than 0.9.0, which a
    /// string comparison gets backwards. A pre-release suffix ("1.0.0-beta.1")
    /// sorts before the release it leads up to.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (aNumbers, aPre) = split(a)
        let (bNumbers, bPre) = split(b)
        for i in 0..<max(aNumbers.count, bNumbers.count) {
            let x = i < aNumbers.count ? aNumbers[i] : 0
            let y = i < bNumbers.count ? bNumbers[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if aPre == bPre { return .orderedSame }
        if aPre.isEmpty { return .orderedDescending }
        if bPre.isEmpty { return .orderedAscending }
        return aPre < bPre ? .orderedAscending : .orderedDescending
    }

    private static func split(_ version: String) -> ([Int], String) {
        let s = normalised(version)
        let halves = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = halves[0].split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return (numbers, halves.count > 1 ? String(halves[1]) : "")
    }

    /// "3 hours ago", for the settings window — in the same English as the rest
    /// of it, and never the "0 seconds from now" a relative date formatter
    /// produces for a check that has only just finished.
    public static func ago(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return plural(Int(seconds / 60), "minute") + " ago"
        case ..<(48 * 3600): return plural(Int(seconds / 3600), "hour") + " ago"
        default: return plural(Int(seconds / 86400), "day") + " ago"
        }
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}
