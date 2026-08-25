import Foundation
import CCFKit
import AppKit

/// Prints what ccfinder can actually see, so a broken install is one command away
/// from being diagnosed instead of guessed at.
enum Doctor {
    static func run() {
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

        let status = launchdStatus(label: "com.klaude.ccfinder")
        check("Sync agent running", status.running,
              status.detail.isEmpty
                  ? "not loaded — run: launchctl bootstrap gui/$(id -u) \(agent.path)"
                  : status.detail)
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
