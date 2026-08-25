import Foundation
import AppKit

/// Prints what ccfinder can actually see, so a broken install is one command away
/// from being diagnosed instead of guessed at.
public enum Doctor {
    public static func run() {
        let fm = FileManager.default

        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✅" : "❌")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        print("Claude in Finder — doctor\n")

        let hasDesktopDir = fm.fileExists(atPath: Paths.desktopSessions.path)
        check("Claude Desktop session index", hasDesktopDir, Paths.desktopSessions.path)

        let sessions = Discovery.sessions()
        let resumable = sessions.filter { $0.cliSessionID != nil }
        let active = sessions.filter { !$0.isArchived }
        check("Sessions found", !sessions.isEmpty,
              "\(sessions.count) total · \(active.count) active · \(resumable.count) resumable")

        if sessions.count > resumable.count {
            print("    ↳ \(sessions.count - resumable.count) session(s) have no CLI transcript id and cannot be reopened by deep link.")
        }

        let transcripts = Discovery.transcriptIndex()
        check("CLI transcripts", !transcripts.isEmpty, "\(transcripts.count) files in \(Paths.cliProjects.path)")

        check("Mirror folder", fm.fileExists(atPath: Paths.mirror.path), Paths.mirror.path)

        let claudeApp = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "claude://resume")!)
        check("claude:// URL handler", claudeApp != nil, claudeApp?.path ?? "no app registered for claude://")

        // Ask about a file that actually exists: LaunchServices will not resolve a
        // handler for a path that is not there, which makes a probe file useless.
        let probe = (try? fm.contentsOfDirectory(at: Paths.mirror, includingPropertiesForKeys: nil))?
            .compactMap { dir -> URL? in
                try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .first { $0.pathExtension == "claudesession" }
            }.first
        if let probe {
            let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
            check(".claudesession handler", handler != nil,
                  handler?.lastPathComponent ?? "not registered — run Scripts/install.sh")
        } else {
            check(".claudesession handler", false, "no session file to probe — run 'ccfinder sync' first")
        }

        // Ask launchd whether the job is actually up. Checking only that the plist
        // exists reports success even when the agent failed to start.
        let agent = Paths.home.appendingPathComponent("Library/LaunchAgents/com.klaude.ccfinder.plist")
        let installed = fm.fileExists(atPath: agent.path)
        check("Sync agent installed", installed, agent.path)

        let config = Config.load()
        print("    settings: layout=\(config.layout.rawValue), "
              + "archive=\(config.showArchive ? "show" : "hide"), "
              + "on-delete=\(config.onFinderDelete.rawValue)")

        // A background agent cannot answer a consent prompt, so a protected folder
        // shows up as one it simply cannot read.
        let mirror = Mirror.fromConfig()
        _ = try? mirror.reconcile()
        let blocked = Mirror.blockedFolders()
        check("All folders readable", blocked.isEmpty,
              blocked.isEmpty ? "\(Set(Discovery.sessions().map(\.cwd)).count) working folders"
                              : "\(blocked.count) unreadable, e.g. \(blocked.prefix(2).joined(separator: ", "))")
        if !blocked.isEmpty {
            print("    ↳ grant Full Disk Access to \"Claude in Finder\" in System Settings →")
            print("      Privacy & Security → Full Disk Access, then: launchctl kickstart -k gui/$(id -u)/com.klaude.ccfinder")
        }

        let ext = finderExtensionEnabled()
        check("Finder menu extension", ext.enabled,
              ext.detail.isEmpty ? "registered and in use" : ext.detail)

        let status = launchdStatus(label: "com.klaude.ccfinder")
        check("Sync agent running", status.running,
              status.detail.isEmpty
                  ? "not loaded — run: launchctl bootstrap gui/$(id -u) \(agent.path)"
                  : status.detail)
    }

    /// The contextual-menu items come from a Finder Sync extension. pluginkit
    /// marks an enabled one with a leading "+".
    private static func finderExtensionEnabled() -> (enabled: Bool, detail: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-m", "-v", "-i", "com.klaude.claude-in-finder.findersync"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do { try task.run() } catch { return (false, "could not run pluginkit") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8),
              text.contains("com.klaude.claude-in-finder.findersync")
        else { return (false, "not registered — re-run Scripts/install.sh") }

        if text.hasPrefix("+") { return (true, "") }
        return (false, "registered but switched off — enable Claude in Finder in "
                     + "System Settings → General → Login Items & Extensions → Finder Extensions")
    }

    /// Shells out to launchctl: there is no public API for querying another job.
    private static func launchdStatus(label: String) -> (running: Bool, detail: String) {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(uid)/\(label)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do { try task.run() } catch { return (false, "could not run launchctl") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return (false, "")
        }

        let running = text.contains("state = running")
        var detail = running ? "" : "loaded but not running"
        if let line = text.split(separator: "\n").first(where: { $0.contains("pid = ") }) {
            detail = "pid\(line.split(separator: "=").last ?? "")"
        }
        return (running, detail.trimmingCharacters(in: .whitespaces))
    }
}
