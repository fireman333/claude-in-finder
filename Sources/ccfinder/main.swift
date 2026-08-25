import Foundation
import CCFKit

let usage = """
ccfinder — mirror Claude Code sessions into Finder

USAGE
  ccfinder sync [options]                        reconcile the mirror once
  ccfinder watch [options]                       stay running and sync on change
  ccfinder open <file.claudesession> [--dry-run] resume (or start) the session a file points at
  ccfinder new [folder] [--dry-run]              start a new session in a folder
  ccfinder archive <file.claudesession>          archive the session (reversible)
  ccfinder unarchive <file.claudesession>        bring an archived session back
  ccfinder delete <file.claudesession> --yes     delete the session record
  ccfinder config [layout|archive] [value]       show or change settings
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
    Watcher(mirror: mirror).run()

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

case "archive", "unarchive":
    guard let path = positional.first else {
        FileHandle.standardError.write(Data("ccfinder \(command): need a .claudesession file\n".utf8))
        exit(2)
    }
    let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let id = SessionFile.meta(in: file)["claude-desktop-id"], !id.isEmpty else {
        FileHandle.standardError.write(Data("ccfinder \(command): \(file.lastPathComponent) is not a session file\n".utf8))
        exit(3)
    }
    do {
        try SessionStore.archive(desktopID: id, archived: command == "archive")
        print("\(command == "archive" ? "archived" : "unarchived"): \(SessionStore.title(desktopID: id) ?? id)")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "delete":
    guard let path = positional.first else {
        FileHandle.standardError.write(Data("ccfinder delete: need a .claudesession file\n".utf8))
        exit(2)
    }
    guard args.contains("--yes") else {
        FileHandle.standardError.write(Data("ccfinder delete: refusing without --yes\n".utf8))
        exit(2)
    }
    let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let id = SessionFile.meta(in: file)["claude-desktop-id"], !id.isEmpty else {
        FileHandle.standardError.write(Data("ccfinder delete: \(file.lastPathComponent) is not a session file\n".utf8))
        exit(3)
    }
    let name = SessionStore.title(desktopID: id) ?? id
    do {
        try SessionStore.delete(desktopID: id)
        try? FileManager.default.removeItem(at: file)
        print("deleted: \(name)")
        print("the transcript is untouched; the record was backed up to \(SessionStore.backupDir.path)")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }

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
          ccfinder config archive show|hide      whether archived sessions appear

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
    if let s = try? updated.reconcile() {
        print("moved \(s.renamed), created \(s.created), removed \(s.removed)")
    }

case "doctor":
    Doctor.run()

case "-h", "--help", "help":
    print(usage)

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)\n".utf8))
    exit(2)
}
