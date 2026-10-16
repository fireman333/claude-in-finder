import Foundation
import CryptoKit

/// Installing a release, when asked to.
///
/// Downloads the release's DMG, checks it against the SHA-256 GitHub recorded
/// for it and against the version it claims to be, then hands over to the
/// installer inside it — the same `install.sh` a person would run by hand.
///
/// That installer stops this app in order to replace it, so it cannot run as one
/// of this app's processes: launchd stops a job's whole process group, and the
/// installer would go down with the agent it was halfway through replacing. It
/// is started in a session of its own instead, out of that group's reach.
public enum UpdateInstaller {

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// What the installer printed, since nobody is watching a terminal.
    public static var logURL: URL { Paths.support.appendingPathComponent("update.log") }
    static var workDir: URL { Paths.support.appendingPathComponent("updates") }

    /// Returns once the installer is running, which will shortly stop the
    /// caller. Everything that can be checked is checked first, and anything
    /// wrong stops here — before a byte of the installed app has been touched.
    public static func install(_ release: Update.Release) throws {
        guard let link = release.dmg, let source = URL(string: link), trusted(source) else {
            throw Failure(message: "the release has no installer image from \(Update.repo)")
        }
        guard let expected = release.sha256?.lowercased(), expected.count == 64 else {
            throw Failure(message: "GitHub gave no checksum for the installer image, so it cannot be verified")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // One install at a time, across every process that can start one — the
        // menu bar, a separate Settings window, the command line. The lock is
        // inherited by the hand-over and held until the installer has finished:
        // a second attempt tidying up mid-install would pull the image out from
        // under an installer that has already removed the old app.
        let lock = open(workDir.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { throw Failure(message: "could not take the update lock") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "an update is already being installed")
        }

        // Holding the lock, anything still here was left by an attempt that died.
        for leftover in (try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? [] {
            if leftover.lastPathComponent.hasPrefix("mount-") { detach(leftover) }
            if leftover.pathExtension == "dmg" { try? fm.removeItem(at: leftover) }
        }

        let image = workDir.appendingPathComponent("Claude-in-Finder-\(release.version).dmg")
        let mount = workDir.appendingPathComponent("mount-\(release.version)")
        // Until the hand-over owns them, a failure on the way leaves nothing behind.
        var handedOver = false
        defer {
            if !handedOver {
                detach(mount)
                try? fm.removeItem(at: image)
            }
        }

        try download(source, to: image)
        let actual = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw Failure(message: "the download does not match the checksum GitHub recorded for it")
        }

        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                       "-mountpoint", mount.path, image.path]) == 0 else {
            throw Failure(message: "the installer image would not open")
        }

        // The image has to be the release it was announced as: the checksum
        // proves it is what GitHub holds, not that it is the version expected.
        let app = mount.appendingPathComponent("Claude in Finder.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let installer = mount.appendingPathComponent("install.sh")
        guard info?["CFBundleShortVersionString"] as? String == release.version,
              fm.fileExists(atPath: installer.path) else {
            throw Failure(message: "the installer image is not version \(release.version)")
        }

        let script = workDir.appendingPathComponent("hand-over.sh")
        try handOver.write(to: script, atomically: true, encoding: .utf8)
        try launch(["/bin/bash", script.path, mount.path, image.path, logURL.path, release.version])
        handedOver = true
        Log.line("installing \(release.version); the installer's output goes to \(logURL.path)")
    }

    /// Only this project's own release downloads. A fixture standing in for
    /// GitHub, as the tests use, may point at a local file and nothing else.
    static func trusted(_ url: URL) -> Bool {
        if let api = ProcessInfo.processInfo.environment["CCF_UPDATE_API"], !api.isEmpty,
           url.isFileURL { return true }
        return url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(Update.repo)/releases/download/")
    }

    private static func download(_ source: URL, to destination: URL) throws {
        if source.isFileURL {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        var request = URLRequest(url: source, timeoutInterval: 60)
        request.setValue("claude-in-finder/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                failure = Failure(message: "GitHub would not hand over the installer image")
                return
            }
            // The temporary file is gone once this handler returns.
            do { try FileManager.default.moveItem(at: location, to: destination) }
            catch { failure = error }
        }
        task.resume()
        guard done.wait(timeout: .now() + 300) == .success else {
            // Stopped, or it finishes later and lands on the next attempt's file.
            task.cancel()
            throw Failure(message: "the download timed out")
        }
        if let failure { throw failure }
    }

    private static func detach(_ mount: URL) {
        guard FileManager.default.fileExists(atPath: mount.path) else { return }
        if run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) != 0 {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        }
        try? FileManager.default.removeItem(at: mount)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Starts a process in a session of its own, and does not wait for it.
    private static func launch(_ arguments: [String]) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, arguments[0], &files, &attributes, &argv, environ)
        guard status == 0 else {
            throw Failure(message: "the installer could not be started (\(String(cString: strerror(status))))")
        }
    }

    /// Runs the release's own installer, then tidies up after it.
    private static let handOver = """
    #!/bin/bash
    # Written by Claude in Finder to install a release on its behalf. It runs in
    # a session of its own because the installer stops the app that started it.
    mount="$1"; image="$2"; log="$3"; version="$4"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    {
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) installing $version"
      bash "$mount/install.sh"
      status=$?
      /usr/bin/hdiutil detach "$mount" -quiet || /usr/bin/hdiutil detach "$mount" -force -quiet
      rmdir "$mount" 2>/dev/null
      rm -f "$image"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) installer finished with status $status"
    } >>"$log" 2>&1

    """
}
