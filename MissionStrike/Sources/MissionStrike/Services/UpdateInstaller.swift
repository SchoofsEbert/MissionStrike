import Foundation

/// Errors from checking for and installing an update; the update window shows their text.
enum UpdateError: LocalizedError {
    case invalidReleaseTag(String)
    case notReplaceable(folder: String)
    case missingAppBundle
    case unsupportedArchitecture
    case toolFailed(step: String, status: Int32)
    case relaunchFailed
    case installedWithoutRelaunch
    case restoreFailed(backup: String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseTag(let tag):
            "The latest release has an unexpected tag (\(tag))."
        case .notReplaceable(let folder):
            "MissionStrike can't replace itself in \(folder). Download the update and install it manually."
        case .missingAppBundle:
            "The download did not contain MissionStrike.app."
        case .unsupportedArchitecture:
            "The download doesn't support this Mac's processor."
        case .toolFailed(let step, let status):
            "Could not \(step) (exit status \(status))."
        case .relaunchFailed:
            "MissionStrike could not start its relaunch helper."
        case .installedWithoutRelaunch:
            "The update is installed, but MissionStrike could not relaunch. Quit and open it again."
        case .restoreFailed(let backup):
            "The previous version could not be put back. It is saved at \(backup)."
        }
    }
}

/// An installed update whose previous version is kept until the relaunch is under way.
struct BundleReplacement: Sendable {
    let appURL: URL
    let backupURL: URL
    let workDirectory: URL

    /// Deletes the previous version; the update stays installed.
    func discardBackup() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Puts the previous version back in place of the update.
    @concurrent
    func rollBack() async throws {
        let fileManager = FileManager.default
        let rejectedURL = workDirectory.appendingPathComponent("Rejected.app")
        do {
            try fileManager.moveItem(at: appURL, to: rejectedURL)
        } catch {
            throw UpdateError.installedWithoutRelaunch
        }
        do {
            try fileManager.moveItem(at: backupURL, to: appURL)
        } catch {
            try? fileManager.moveItem(at: rejectedURL, to: appURL)
            throw UpdateError.restoreFailed(backup: backupURL.path)
        }
        try? fileManager.removeItem(at: workDirectory)
    }
}

/// Downloads, verifies and swaps in an update. Everything runs off the main actor:
/// unpacking a bundle and checking its signature take long enough to stall the event tap.
enum UpdateInstaller {
    /// Downloads the zip, extracts it, verifies the signature, version and architecture,
    /// removes quarantine, and replaces the app bundle at `appURL`. Nothing at `appURL`
    /// changes until the update has passed every check.
    @concurrent
    static func install(
        from downloadURL: URL,
        expectedVersion: String,
        replacing appURL: URL,
        progress: @escaping @Sendable (Double?) -> Void,
        status: @escaping @Sendable (String) async -> Void
    ) async throws -> BundleReplacement {
        let fileManager = FileManager.default
        try checkReplaceable(appURL)

        // A scratch directory on the app's volume, so the final swap is a rename and the
        // previous version can stay beside it until the update is in place.
        let workDirectory = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true
        )
        var keepWorkDirectory = false
        defer {
            if !keepWorkDirectory { try? fileManager.removeItem(at: workDirectory) }
        }

        let zipURL = workDirectory.appendingPathComponent("MissionStrike.app.zip")
        try await download(downloadURL, to: zipURL, progress: progress)

        await status("Extracting…")
        let extractDirectory = workDirectory.appendingPathComponent("Extracted")
        try await run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDirectory.path], step: "extract the update")
        let extractedApp = extractDirectory.appendingPathComponent("MissionStrike.app")
        guard fileManager.fileExists(atPath: extractedApp.path) else {
            throw UpdateError.missingAppBundle
        }

        // Only install builds signed with the MissionStrike certificate, and only the
        // version that was offered (an older signed release must not be replayed).
        await status("Verifying…")
        try CodeSigning.verifyUpdate(at: extractedApp, expectedVersion: expectedVersion)
        try verifyArchitecture(of: extractedApp)

        await status("Removing quarantine…")
        try await run("/usr/bin/xattr", ["-cr", extractedApp.path], step: "remove the quarantine flag")

        await status("Installing…")
        do {
            let replacement = try replace(appURL, with: extractedApp, workDirectory: workDirectory)
            keepWorkDirectory = true
            return replacement
        } catch {
            if case UpdateError.restoreFailed = error { keepWorkDirectory = true }
            throw error
        }
    }

    /// Starts a helper that waits for this process to exit, then opens the app again.
    /// Throws if the helper isn't running, so the caller never quits without a relaunch.
    @concurrent
    static func launchRelaunchHelper(for appURL: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        // The path is passed as an argument rather than spliced into the script.
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            open "$1"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "relaunch", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.relaunchFailed
        }
        guard process.isRunning else { throw UpdateError.relaunchFailed }
    }

    // MARK: - Steps

    /// Fails before downloading when the app can't replace itself, for example in a folder
    /// the user can't write to, or when macOS runs it from a read-only translocated copy.
    private static func checkReplaceable(_ appURL: URL) throws {
        let fileManager = FileManager.default
        let folder = appURL.deletingLastPathComponent()
        guard appURL.pathExtension == "app",
              fileManager.isWritableFile(atPath: folder.path),
              fileManager.isWritableFile(atPath: appURL.path) else {
            throw UpdateError.notReplaceable(folder: folder.path)
        }
    }

    /// Refuses a build that can't run natively on this Mac.
    private static func verifyArchitecture(of app: URL) throws {
        #if arch(arm64)
        let required = NSBundleExecutableArchitectureARM64
        #else
        let required = NSBundleExecutableArchitectureX86_64
        #endif
        let architectures = Bundle(url: app)?.executableArchitectures?.map(\.intValue) ?? []
        guard architectures.contains(required) else { throw UpdateError.unsupportedArchitecture }
    }

    /// Moves the current bundle aside and the update into its place. If the second move
    /// fails, the current bundle goes back.
    private static func replace(_ appURL: URL, with newApp: URL, workDirectory: URL) throws -> BundleReplacement {
        let fileManager = FileManager.default
        let backupURL = workDirectory.appendingPathComponent("Previous.app")
        try fileManager.moveItem(at: appURL, to: backupURL)
        do {
            try fileManager.moveItem(at: newApp, to: appURL)
        } catch {
            do {
                try fileManager.moveItem(at: backupURL, to: appURL)
            } catch {
                throw UpdateError.restoreFailed(backup: backupURL.path)
            }
            throw error
        }
        return BundleReplacement(appURL: appURL, backupURL: backupURL, workDirectory: workDirectory)
    }

    private static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Runs a tool and waits for it to exit without holding a thread.
    private static func run(_ path: String, _ arguments: [String], step: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw UpdateError.toolFailed(step: step, status: status) }
    }
}

/// Receives one download's progress and file. The async `URLSession.download` methods
/// don't report progress to their delegate, so the download uses its own session.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Set before the task starts; afterwards only the session's serial delegate queue
    /// touches this object.
    var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var lastPercent = -1
    private var fileError: Error?

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Without a Content-Length the progress bar stays indeterminate.
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            fileError = URLError(.badServerResponse)
            return
        }
        // The file is deleted when this method returns, so move it now.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fileError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? fileError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
