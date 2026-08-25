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

    public var layout: Layout = .workdir
    /// Whether sessions archived in Claude appear in the Archive subfolder at all.
    public var showArchive: Bool = true

    public init(layout: Layout = .workdir, showArchive: Bool = true) {
        self.layout = layout
        self.showArchive = showArchive
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
                        ? "(archived sessions appear in the Archive subfolder)"
                        : "(archived sessions are not mirrored)")

        config file  \(Self.url.path)
        """
    }
}
