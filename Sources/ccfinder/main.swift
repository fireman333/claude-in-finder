import Foundation
import CCFKit

let usage = """
ccfinder — mirror Claude Code sessions into Finder

USAGE
  ccfinder sync [--archived] [--no-prune] [-v]   reconcile the mirror once
  ccfinder watch [--archived] [--no-prune]       stay running and sync on change
  ccfinder open <file.claudesession> [--dry-run] resume (or start) the session a file points at
  ccfinder new [folder] [--dry-run]              start a new session in a folder
  ccfinder doctor                                report what it can and cannot see

The mirror lives at ~/Claude Sessions (override with CCF_MIRROR).
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

let includeArchived = args.contains("--archived")
let prune = !args.contains("--no-prune")
let verbose = args.contains("-v") || args.contains("--verbose")
let positional = args.filter { !$0.hasPrefix("-") }

let mirror = Mirror(includeArchived: includeArchived, prune: prune, verbose: verbose)

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
    let folder = positional.first.map { ($0 as NSString).expandingTildeInPath }
        ?? FileManager.default.currentDirectoryPath
    guard let target = SessionFile.newSessionLink(cwd: folder) else { exit(3) }
    if args.contains("--dry-run") {
        print(target.absoluteString)
        exit(0)
    }
    Task { _ = await SessionFile.launch(target); exit(0) }
    RunLoop.main.run()

case "doctor":
    Doctor.run()

case "-h", "--help", "help":
    print(usage)

default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n\n\(usage)\n".utf8))
    exit(2)
}
