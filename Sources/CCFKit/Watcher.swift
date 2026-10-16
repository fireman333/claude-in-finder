import Foundation
import CoreServices

/// Watches Claude Desktop's session directory and re-syncs on change.
///
/// Desktop rewrites local_<uuid>.json when a session is created, retitled,
/// archived or used, so a file-level watch on that one directory covers every
/// event we care about. A slow full reconcile still runs periodically in case
/// an event is ever missed.
public final class Watcher {
    /// Rebuilt for every pass rather than held: the settings it reads can change
    /// while the agent runs, and a Mirror captures them at construction. Holding
    /// one meant the agent kept syncing to the old layout and quietly undid every
    /// change made through settings.
    private let makeMirror: @Sendable () -> Mirror
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.klaude.ccfinder.watch")
    private var pending: DispatchWorkItem?
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var watched: [String] = []
    /// What the last pass wrote, so its own echo can be told from a real change.
    private var selfWrites: Set<String> = []
    private var verify: DispatchWorkItem?
    /// Passes in a row, each woken by the file system, that went on to move
    /// files. A rename settles in one or two; a run of them means the mirror is
    /// answering its own moves, and every such pass reads every session on disk.
    /// Once the run is long, waiting longer between passes caps what a loop
    /// nobody has found yet can cost — one once ran for days at a pass every two
    /// and a half seconds. Only moves count: a conversation in progress rewrites
    /// its preview every few seconds, which is work, not a loop.
    private var busyStreak = 0
    private static let streakLimit = 5
    private static let slowest: TimeInterval = 60

    public init(mirror: @escaping @Sendable () -> Mirror, debounce: TimeInterval = 1.5) {
        self.makeMirror = mirror
        self.debounce = debounce
    }

    /// For a one-off watch with fixed options, as the command line uses.
    public convenience init(mirror: Mirror, debounce: TimeInterval = 1.5) {
        self.init(mirror: { mirror }, debounce: debounce)
    }

    /// Starts watching and returns. FSEvents and the periodic timer both run on a
    /// dispatch queue, so nothing here needs a run loop of its own — an earlier
    /// version parked a thread on one and spun a core doing nothing.
    public func start(fullResyncEvery: TimeInterval = 300) {
        // On the queue, like every other pass: run here it would race a "Sync Now"
        // arriving while the app is still starting, and the two would trample the
        // watcher's own state. The reconcile lock guards the mirror, not this.
        queue.async { [weak self] in self?.sync(reason: "startup") }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + fullResyncEvery, repeating: fullResyncEvery)
        timer.setEventHandler { [weak self] in self?.sync(reason: "periodic") }
        timer.resume()
        self.timer = timer
    }

    /// Starts watching and blocks, for the command-line `watch` subcommand.
    public func run(fullResyncEvery: TimeInterval = 300) {
        start(fullResyncEvery: fullResyncEvery)
        RunLoop.main.run()
    }

    /// Runs a pass right now, off the caller's thread.
    public func syncNow() {
        queue.async { [weak self] in self?.sync(reason: "manual") }
    }



    /// Watches Claude's session directory *and* every mirror folder, so that
    /// dragging a file into or out of Archive is picked up as quickly as a change
    /// made inside Claude. The set of mirror folders grows as you work in new
    /// projects, so the stream is rebuilt whenever it changes.
    private func restartStream(paths: [String]) {
        guard paths != watched else { return }
        watched = paths

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !paths.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            for i in 0..<count where i < paths.count {
                events.append((paths[i], eventFlags[i]))
            }
            Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().schedule(events)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // UseCFTypes so the callback is handed real strings: which paths changed
        // is what tells our own writes from yours.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags
        ) else {
            Log.line("could not start FSEvents for \(paths.count) path(s)")
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        Log.line("watching \(paths.count) folder(s)")
    }

    /// The only flags that can mean "this is the mirror's own writing coming
    /// back": a file's contents or its metadata changing. A file going away, being
    /// renamed, a warning that events were dropped, a watched folder moving out
    /// from under us — those have to be looked at, whatever the path.
    ///
    /// Said as what is allowed rather than what is not, so a flag nobody here has
    /// thought about wakes the watcher rather than being quietly ignored. The
    /// first version of this listed what to refuse and forgot the dropped-events
    /// warnings, which are precisely the ones that must never be missed.
    ///
    /// `ItemCreated` is on the list because these flags accumulate over a path's
    /// history rather than describing the event in hand: a file written long ago
    /// still arrives marked created every time it is touched, so refusing it would
    /// mean never recognising anything.
    private static let benign = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemIsFile
            | kFSEventStreamEventFlagItemIsDir
            | kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemModified
            | kFSEventStreamEventFlagItemInodeMetaMod
            | kFSEventStreamEventFlagItemChangeOwner
            | kFSEventStreamEventFlagItemXattrMod
            | kFSEventStreamEventFlagItemFinderInfoMod
    )

    private func schedule(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        // A pass gives every file it mirrors the conversation's own dates, and
        // writing dates in a folder we watch is a change like any other. The event
        // comes back a second later and buys a whole second pass that can only ever
        // find nothing — one real change, two passes, for as long as you keep
        // working. It is that echo when every event is a plain edit to a file this
        // process just wrote. Dragging one into Archive/ is a rename, so it wakes
        // us however familiar the path looks, as does any warning that events were
        // dropped and the folder needs rescanning.
        if !events.isEmpty, !selfWrites.isEmpty,
           events.allSatisfy({ event in
               event.flags & ~Self.benign == 0
                   && selfWrites.contains(Mirror.normalize(URL(fileURLWithPath: event.path)).path)
           }) {
            selfWrites = []          // never swallow twice on one pass's account
            // Not simply dropped. If that reading is ever wrong, the change behind
            // it would wait for the periodic resync, minutes away; look again
            // shortly instead, and let any real event arriving first take over.
            let check = DispatchWorkItem { [weak self] in self?.sync(reason: "after echo") }
            verify?.cancel()
            verify = check
            queue.asyncAfter(deadline: .now() + 20, execute: check)
            return
        }

        selfWrites = []
        verify?.cancel()
        verify = nil
        // While slowed down, a pass already waiting is left to run when it was
        // due. Pushing it back with every event would mean a steady stream of
        // them — an active conversation — never got a pass at all.
        if busyStreak >= Self.streakLimit, pending != nil { return }
        pending?.cancel()
        // Forgotten as it starts: a finished item never reads as cancelled, so
        // one left in `pending` would look forever like a pass still to come.
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.sync(reason: "fsevent")
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay(), execute: work)
    }

    /// The usual debounce, doubling for each pass past the limit of a busy run.
    private func delay() -> TimeInterval {
        guard busyStreak >= Self.streakLimit else { return debounce }
        let doublings = Double(min(busyStreak - Self.streakLimit + 1, 10))
        return min(debounce * pow(2, doublings), Self.slowest)
    }

    private func sync(reason: String) {
        do {
            let mirror = makeMirror()
            let s = try mirror.reconcile()
            // Every pass is logged when asked to be verbose, changes or not: how
            // many passes one change costs is otherwise invisible.
            let changed = s.created + s.renamed + s.updated + s.removed > 0
            if changed || mirror.verbose {
                Log.line("[\(reason)] +\(s.created) ~\(s.updated) ↻\(s.renamed) -\(s.removed)")
            }
            if s.renamed == 0 {
                busyStreak = 0
            } else if reason == "fsevent" {
                busyStreak += 1
                if busyStreak == Self.streakLimit {
                    Log.line("\(busyStreak) passes in a row each moved files; slowing down")
                }
            }
            selfWrites = s.selfWrites
            // New project folders appear as you work; follow them.
            restartStream(paths: s.watchPaths)
        } catch {
            Log.line("[\(reason)] sync failed: \(error.localizedDescription)")
            // Nothing is known about what was written, so claim nothing.
            selfWrites = []
            restartStream(paths: makeMirror().watchPaths())
        }
    }
}

public enum Log {
    private static let lock = NSLock()
    private static var sinceCheck = 100       // so the first line checks, then every 100

    public static func line(_ msg: String) {
        let df = ISO8601DateFormatter()
        let text = "\(df.string(from: Date())) \(msg)\n"
        FileHandle.standardError.write(Data(text.utf8))
        trimIfHuge()
    }

    private static let cap = 8 * 1024 * 1024
    private static let keep = 2 * 1024 * 1024

    /// Keeps the agent's log from growing without bound.
    ///
    /// launchd opened this file and holds the descriptor, so it cannot be rotated
    /// out from under it — renaming it would leave every later line going to the
    /// file under its old name. Shortening it in place is safe only if the
    /// descriptor is in append mode, where each write seeks to the end on its own;
    /// otherwise writing would carry on at the offset it had reached and leave a
    /// hole megabytes wide. Both that and the file being the one we are actually
    /// writing to are checked rather than assumed, because the command line shares
    /// this code and its output belongs to whoever ran it.
    private static func trimIfHuge() {
        lock.lock(); defer { lock.unlock() }
        sinceCheck += 1
        guard sinceCheck >= 100 else { return }
        sinceCheck = 0

        guard fcntl(STDERR_FILENO, F_GETFL) & O_APPEND != 0 else { return }
        let url = Paths.support.appendingPathComponent("ccfinder.log")
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > cap,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return }

        var here = stat()
        guard fstat(STDERR_FILENO, &here) == 0, here.st_ino == inode else { return }

        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        // Keep the end of it: what a log is for is the last thing that happened.
        try? handle.seek(toOffset: UInt64(size - keep))
        guard var tail = try? handle.readToEnd() else { return }
        // Begin at a line boundary rather than halfway through whatever was there.
        if let firstBreak = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: firstBreak)...]
        }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: tail)
        try? handle.truncate(atOffset: UInt64(tail.count))
    }
}
