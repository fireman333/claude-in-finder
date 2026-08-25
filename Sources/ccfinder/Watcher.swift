import Foundation
import CCFKit
import CoreServices

/// Watches Claude Desktop's session directory and re-syncs on change.
///
/// Desktop rewrites local_<uuid>.json when a session is created, retitled,
/// archived or used, so a file-level watch on that one directory covers every
/// event we care about. A slow full reconcile still runs periodically in case
/// an event is ever missed.
final class Watcher {
    private let mirror: Mirror
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.klaude.ccfinder.watch")
    private var pending: DispatchWorkItem?
    private var stream: FSEventStreamRef?

    init(mirror: Mirror, debounce: TimeInterval = 1.5) {
        self.mirror = mirror
        self.debounce = debounce
    }

    func run(fullResyncEvery: TimeInterval = 300) {
        sync(reason: "startup")

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let paths = [Paths.desktopSessions.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags
        ) else {
            FileHandle.standardError.write(Data("ccfinder: could not start FSEvents\n".utf8))
            exit(1)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + fullResyncEvery, repeating: fullResyncEvery)
        timer.setEventHandler { [weak self] in self?.sync(reason: "periodic") }
        timer.resume()

        RunLoop.main.run()
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
        } catch {
            Log.line("[\(reason)] sync failed: \(error.localizedDescription)")
        }
    }
}

enum Log {
    static func line(_ msg: String) {
        let df = ISO8601DateFormatter()
        let text = "\(df.string(from: Date())) \(msg)\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}
