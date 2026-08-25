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

        let agent = Paths.home.appendingPathComponent("Library/LaunchAgents/com.klaude.ccfinder.plist")
        check("Sync agent installed", fm.fileExists(atPath: agent.path), agent.path)
    }
}
