import Foundation
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "LegacyBundleRename")

/// Moves a copy still installed as MissionStrike.app to Vantage.app. Copies from before the
/// rename update in place, so the first Vantage launch finds itself under the old name.
/// The bundle identifier and signature stay the same, so Accessibility stays granted.
@MainActor
enum LegacyBundleRename {
    nonisolated static let legacyBundleName = "MissionStrike.app"
    nonisolated static let bundleName = "Vantage.app"
    private static let reregisterLoginItemKey = "reregisterLoginItemAfterRename"

    /// Where the bundle at `appURL` should move, or nil when it needn't or can't.
    nonisolated static func destination(for appURL: URL, fileManager: FileManager = .default) -> URL? {
        guard appURL.lastPathComponent == legacyBundleName else { return nil }
        let folder = appURL.deletingLastPathComponent()
        let target = folder.appendingPathComponent(bundleName)
        guard !fileManager.fileExists(atPath: target.path),
              fileManager.isWritableFile(atPath: folder.path) else {
            return nil
        }
        return target
    }

    /// Renames the running bundle and relaunches it from the new path. Returns true when the
    /// caller should stop launching: this process quits and the renamed copy takes over.
    static func renameAndRelaunchIfNeeded() -> Bool {
        finishLoginItemMove()
        let appURL = Bundle.main.bundleURL
        guard let target = destination(for: appURL) else { return false }

        // The login item points at the old path; register it again from the new one.
        let loginItemEnabled = SMAppService.mainApp.status == .enabled
        if loginItemEnabled { try? SMAppService.mainApp.unregister() }
        do {
            try FileManager.default.moveItem(at: appURL, to: target)
        } catch {
            logger.error("Could not rename \(appURL.path) to \(target.path): \(error.localizedDescription)")
            if loginItemEnabled { try? SMAppService.mainApp.register() }
            return false
        }
        if loginItemEnabled { UserDefaults.standard.set(true, forKey: reregisterLoginItemKey) }

        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$1\"",
                             "relaunch", target.path]
        do {
            try process.run()
        } catch {
            // Keep running from the moved bundle; the next launch picks up the new path.
            logger.error("Could not relaunch after the rename: \(error.localizedDescription)")
            return false
        }
        logger.info("Renamed \(appURL.path) to \(target.path); relaunching.")
        return true
    }

    private static func finishLoginItemMove() {
        guard UserDefaults.standard.bool(forKey: reregisterLoginItemKey),
              Bundle.main.bundleURL.lastPathComponent == bundleName else { return }
        UserDefaults.standard.removeObject(forKey: reregisterLoginItemKey)
        do {
            try SMAppService.mainApp.register()
        } catch {
            logger.error("Could not register the login item again: \(error.localizedDescription)")
        }
    }
}
