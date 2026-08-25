import Foundation
import CCFKit

let usage = """
ccfinder — mirror Claude Code sessions into Finder

USAGE
  ccfinder sync [options]                        reconcile the mirror once
  ccfinder watch [options]                       stay running and sync on change
  ccfinder open <file.claudesession> [--dry-run] resume (or start) the session a file points at
  ccfinder new [folder] [--dry-run]              start a new session in a folder
  ccfinder link <file...>                        print the claude:// link a file stands for
  ccfinder archive <file...>                     archive one or more sessions (reversible)
  ccfinder unarchive <file...>                   bring archived sessions back
  ccfinder delete <file...> --yes                delete session records
  ccfinder config [layout|archive|on-delete] [v] show or change settings
  ccfinder update [--if-due]                     check GitHub for a newer release
  ccfinder doctor                                report what it can and cannot see

Sessions are mirrored into a "Claude Sessions" folder inside the directory each
session ran in; the ones you archived in Claude go in its Archive subfolder. Sessions whose working directory no longer exists fall back to
~/Claude Sessions/_Unavailable (override the root with CCF_MIRROR).

OPTIONS
  --no-archived       leave archived sessions out of the mirror entirely
  --central           put everything under ~/Claude Sessions for this run
  --no-git-exclude    do not touch .git/info/exclude in git repositories
  --no-prune          never delete a mirrored file
  -v                  log every change
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

let skipArchived = args.contains("--no-archived")
let prune = !args.contains("--no-prune")
let verbose = args.contains("-v") || args.contains("--verbose")
let positional = args.filter { !$0.hasPrefix("-") }

let mirror = Mirror.fromConfig(
    forceCentral: args.contains("--central"),
    forceSkipArchived: skipArchived,
    prune: prune,
    gitExclude: !args.contains("--no-git-exclude"),
    verbose: verbose
)

switch command {

case "sync":
    do {
        let s = try mirror.reconcile()
        print("created \(s.created), updated \(s.updated), renamed \(s.renamed), removed \(s.removed)")
        print("mirror: \(Paths.mirror.path)")
    } catch {
        FileHandle.standardError.write(Data("sync failed: \(error)\n".utf8))
        exit(1)
    }

case "watch":
    // Rebuild per pass so a settings change is picked up without a restart; the
    // flags given on this command line still win each time.
    let forceCentral = args.contains("--central")
    let noGitExclude = args.contains("--no-git-exclude")
    Watcher(mirror: {
        Mirror.fromConfig(
            forceCentral: forceCentral,
            forceSkipArchived: skipArchived,
            prune: prune,
            gitExclude: !noGitExclude,
            verbose: verbose
        )
    }).run()

case "open":
    guard let path = positional.first else {
        FileHandle.standardError.write(Data("ccfinder open: need a file\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let target = SessionFile.deepLink(for: url) else {
        FileHandle.standardError.write(Data("ccfinder open: no session in \(url.lastPathComponent)\n".utf8))
        exit(3)
    }
    if args.contains("--dry-run") {
        print(target.absoluteString)
        exit(0)
    }
    Task { _ = await SessionFile.launch(target); exit(0) }
    RunLoop.main.run()

case "new":
    let requested = positional.first ?? FileManager.default.currentDirectoryPath
    let folder = SessionFile.workingDirectory(for: requested)
    guard let target = SessionFile.newSessionLink(cwd: folder) else { exit(3) }
    if args.contains("--dry-run") {
        print(target.absoluteString)
        exit(0)
    }
    Task { _ = await SessionFile.launch(target); exit(0) }
    RunLoop.main.run()

case "link":
    // Pipe it wherever you keep notes: `ccfinder link x.claudesession | pbcopy`.
    guard !positional.isEmpty else {
        FileHandle.standardError.write(Data("ccfinder link: need one or more .claudesession files\n".utf8))
        exit(2)
    }
    var linkFailures = 0
    for path in positional {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if let target = SessionFile.deepLink(for: file) {
            print(target.absoluteString)
        } else {
            FileHandle.standardError.write(Data("no session in \(file.lastPathComponent)\n".utf8))
            linkFailures += 1
        }
    }
    if linkFailures > 0 { exit(1) }

case "archive", "unarchive":
    guard !positional.isEmpty else {
        FileHandle.standardError.write(Data("ccfinder \(command): need one or more .claudesession files\n".utf8))
        exit(2)
    }
    let archiving = command == "archive"
    var archiveFailures = 0
    for path in positional {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let id = SessionFile.meta(in: file)["claude-desktop-id"], !id.isEmpty else {
            FileHandle.standardError.write(Data("skipped \(file.lastPathComponent): not a session file\n".utf8))
            archiveFailures += 1
            continue
        }
        do {
            try SessionStore.archive(desktopID: id, archived: archiving)
            SessionStore.moveMirrorFile(file, intoArchive: archiving)
            print("\(archiving ? "archived" : "unarchived"): \(SessionStore.title(desktopID: id) ?? id)")
        } catch {
            FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
            archiveFailures += 1
        }
    }
    if archiveFailures > 0 { exit(1) }

case "delete":
    guard !positional.isEmpty else {
        FileHandle.standardError.write(Data("ccfinder delete: need one or more .claudesession files\n".utf8))
        exit(2)
    }
    guard args.contains("--yes") else {
        FileHandle.standardError.write(Data("ccfinder delete: refusing without --yes\n".utf8))
        exit(2)
    }
    var deleteFailures = 0
    for path in positional {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let id = SessionFile.meta(in: file)["claude-desktop-id"], !id.isEmpty else {
            FileHandle.standardError.write(Data("skipped \(file.lastPathComponent): not a session file\n".utf8))
            deleteFailures += 1
            continue
        }
        let name = SessionStore.title(desktopID: id) ?? id
        do {
            try SessionStore.delete(desktopID: id)
            try? FileManager.default.removeItem(at: file)
            print("deleted: \(name)")
        } catch {
            FileHandle.standardError.write(Data("\(name): \(error.localizedDescription)\n".utf8))
            deleteFailures += 1
        }
    }
    print("transcripts are untouched; records were backed up to \(SessionStore.backupDir.path)")
    if deleteFailures > 0 { exit(1) }

case "config":
    var config = Config.load()
    if positional.isEmpty {
        print(config.summary)
        break
    }
    guard positional.count >= 2 else {
        FileHandle.standardError.write(Data("""
        usage:
          ccfinder config                        show current settings
          ccfinder config layout workdir|central where session files are kept
          ccfinder config archive show|hide      whether the Archive folder is visible
          ccfinder config new-file show|hide      whether folders get a + New Session file
          ccfinder config updates on|off         whether to check GitHub for new releases
          ccfinder config on-delete archive|delete  what deleting a file means
                                                 (from Archive it always deletes)

        """.utf8))
        exit(2)
    }
    switch (positional[0], positional[1]) {
    case ("layout", let value):
        guard let layout = Config.Layout(rawValue: value) else {
            FileHandle.standardError.write(Data("layout must be workdir or central\n".utf8))
            exit(2)
        }
        config.layout = layout
    case ("archive", let value) where ["show", "hide", "on", "off"].contains(value):
        config.showArchive = (value == "show" || value == "on")
    case ("new-file", let value) where ["show", "hide", "on", "off"].contains(value):
        config.newSessionFile = (value == "show" || value == "on")
    case ("updates", let value) where ["show", "hide", "on", "off"].contains(value):
        config.updateCheck = (value == "show" || value == "on")
    case ("on-delete", let value):
        guard let action = Config.DeleteAction(rawValue: value) else {
            FileHandle.standardError.write(Data("on-delete must be archive or delete\n".utf8))
            exit(2)
        }
        config.onFinderDelete = action
    default:
        FileHandle.standardError.write(Data("unknown setting: \(positional[0])\n".utf8))
        exit(2)
    }

    do { try config.save() } catch {
        FileHandle.standardError.write(Data("could not save settings: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print(config.summary)

    // Apply it straight away rather than waiting for the agent to notice.
    print("")
    let updated = Mirror.fromConfig(verbose: verbose)
    if let stats = try? updated.reconcile() {
        print("moved \(stats.renamed), created \(stats.created), removed \(stats.removed)")
    }

case "update":
    // --if-due is the scheduled check the background agent runs: it respects the
    // setting and the once-a-day window, and says why when it does not look.
    if args.contains("--if-due") {
        guard Config.load().updateCheck else {
            print("update checks are off — turn them on with 'ccfinder config updates on'")
            break
        }
        guard Update.isDue else {
            let last = Update.loadState().lastCheck.map { " (last checked \(Update.ago($0)))" } ?? ""
            print("checked recently, not looking again\(last)")
            break
        }
    }
    do {
        switch try Update.check() {
        case .upToDate(let version):
            print("up to date — \(version) is the latest release")
        case .available(let release):
            print("update available: \(release.version)   (this is \(AppVersion.current))")
            if let name = release.name { print(name) }
            print(release.url)
        }
    } catch {
        FileHandle.standardError.write(
            Data("could not check for updates: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "doctor":
    Doctor.run()

case "-h", "--help", "help":
    print(usage)

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)\n".utf8))
    exit(2)
}
