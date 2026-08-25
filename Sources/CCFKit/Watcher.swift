import Foundation
import CoreServices

/// Watches Claude Desktop's session directory and re-syncs on change.
///
/// Desktop rewrites local_<uuid>.json when a session is created, retitled,
/// archived or used, so a file-level watch on that one directory covers every
/// event we care about. A slow full reconcile still runs periodically in case
/// an event is ever missed.
public final class Watcher {
    private let mirror: Mirror
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.klaude.ccfinder.watch")
    private var pending: DispatchWorkItem?
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var watched: [String] = []

    public init(mirror: Mirror, debounce: TimeInterval = 1.5) {
        self.mirror = mirror
        self.debounce = debounce
    }

    /// Starts watching and returns. FSEvents and the periodic timer both run on a
    /// dispatch queue, so nothing here needs a run loop of its own — an earlier
    /// version parked a thread on one and spun a core doing nothing.
    public func start(fullResyncEvery: TimeInterval = 300) {
        sync(reason: "startup")
        restartStream()

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
    private func restartStream() {
        let paths = mirror.watchPaths()
        guard paths != watched else { return }
        watched = paths

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !paths.isEmpty else { return }

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
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

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync(reason: "fsevent") }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func sync(reason: String) {
        do {
            let s = try mirror.reconcile()
            if s.created + s.renamed + s.updated + s.removed > 0 {
                Log.line("[\(reason)] +\(s.created) ~\(s.updated) ↻\(s.renamed) -\(s.removed)")
            }
            // New project folders appear as you work; follow them.
            restartStream()
        } catch {
            Log.line("[\(reason)] sync failed: \(error.localizedDescription)")
        }
    }
}

public enum Log {
    public static func line(_ msg: String) {
        let df = ISO8601DateFormatter()
        let text = "\(df.string(from: Date())) \(msg)\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}
