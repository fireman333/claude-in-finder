import Foundation

/// Runs work with a deadline.
///
/// Reading a file is not reliably fast on macOS. A file that lives in iCloud may
/// only be a placeholder, and reading it blocks while the real bytes are fetched;
/// a folder the process has not been granted access to blocks on a consent prompt
/// that a background agent can never answer. Neither reports an error — they just
/// never return. Anything touching a path outside our own state directory goes
/// through here.
public enum TimeLimited {

    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// Returns nil if `work` did not finish in time. The worker thread stays
    /// parked on whatever blocked it; that is the cost of not blocking everything
    /// else behind it.
    public static func run<T>(_ seconds: TimeInterval,
                              _ work: @escaping @Sendable () -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        DispatchQueue.global(qos: .utility).async {
            box.value = work()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }

    /// Reads a text file, giving up rather than waiting forever.
    public static func text(at url: URL, seconds: TimeInterval = 2) -> String? {
        run(seconds) { try? String(contentsOf: url, encoding: .utf8) } ?? nil
    }

    /// Reads a file as bytes, mapped rather than copied where the system allows
    /// it. Transcripts run to tens of megabytes, and the ones being read here are
    /// scanned once and dropped.
    public static func data(at url: URL, seconds: TimeInterval = 2) -> Data? {
        run(seconds) { try? Data(contentsOf: url, options: .mappedIfSafe) } ?? nil
    }
}
