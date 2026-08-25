import Foundation

/// User settings, shared by the CLI and the background agent.
///
/// Kept in a plain JSON file rather than UserDefaults so that the agent, the app
/// and the command line all read exactly the same thing, and so you can see and
/// edit it without a tool.
public struct Config: Codable, Equatable {

    public enum Layout: String, Codable, CaseIterable {
        /// A "Claude Sessions" folder inside each working directory.
        case workdir
        /// Everything together under ~/Claude Sessions.
        case central
    }

    /// What deleting a session file in Finder should mean.
    public enum DeleteAction: String, Codable, CaseIterable {
        /// Archive the session — the conversation is kept. The safe default.
        case archive
        /// Delete the session from Claude, as the Delete service does.
        case delete
    }

    public var layout: Layout = .workdir
    /// Whether the Archive folder is visible in Finder. Archived sessions are
    /// mirrored either way; hiding sets the folder's hidden flag, so the contents
    /// stay reachable through "Open Archive Folder".
    public var showArchive: Bool = true
    public var onFinderDelete: DeleteAction = .archive

    public init(layout: Layout = .workdir,
                showArchive: Bool = true,
                onFinderDelete: DeleteAction = .archive) {
        self.layout = layout
        self.showArchive = showArchive
        self.onFinderDelete = onFinderDelete
    }

    // Older config files predate onFinderDelete; default it rather than failing
    // to decode and silently resetting every other setting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .workdir
        showArchive = try c.decodeIfPresent(Bool.self, forKey: .showArchive) ?? true
        onFinderDelete = try c.decodeIfPresent(DeleteAction.self, forKey: .onFinderDelete) ?? .archive
    }

    public static var url: URL { Paths.support.appendingPathComponent("config.json") }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url)
    }

    public var summary: String {
        """
        layout       \(layout.rawValue)   \(layout == .workdir
                        ? "(a Claude Sessions folder inside each working directory)"
                        : "(everything under \(Paths.mirror.path))")
        archive      \(showArchive ? "show" : "hide")   \(showArchive
                        ? "(the Archive folder is visible)"
                        : "(the Archive folder is hidden; open it from the right-click menu)")
        on-delete    \(onFinderDelete.rawValue)   \(onFinderDelete == .archive
                        ? "(deleting a session file in Finder archives the session)"
                        : "(deleting a session file in Finder deletes the session)")

        config file  \(Self.url.path)
        """
    }
}
