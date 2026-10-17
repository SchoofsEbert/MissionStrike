import Foundation
import Cocoa
import os.log

private let logger = Logger(
    subsystem: "io.github.schoofsebert.missionstrike",
    category: "UpdateChecker"
)

/// Decoded payload from the GitHub Releases API.
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

/// Release tags (`v2.8.0`) and the version comparison the update check uses.
enum ReleaseVersion {
    /// The version in a release tag. Only a single leading `v` is removed, so the rest of
    /// the tag is never altered.
    static func fromTag(_ tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        return components(of: version) == nil ? nil : version
    }

    /// Numeric comparison, component by component ("2.10.0" > "2.9.1"). Missing components
    /// count as zero, and a suffix such as "-beta" is ignored. Unparseable versions are never newer.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let remoteParts = components(of: remote), let localParts = components(of: local) else {
            return false
        }
        for index in 0..<max(remoteParts.count, localParts.count) {
            let remoteValue = index < remoteParts.count ? remoteParts[index] : 0
            let localValue = index < localParts.count ? localParts[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return false
    }

    private static func components(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.prefix(while: \.isNumber)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}

/// Checks for new releases by polling the GitHub Releases API.
/// No external dependencies — compares semantic version tags against
/// the running app version and offers the update in the update window.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private static let repoOwner = "SchoofsEbert"
    private static let repoName = "MissionStrike"
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    )!

    /// UserDefaults key for the last successful check timestamp.
    private static let lastCheckKey = "lastUpdateCheckTimestamp"

    /// UserDefaults key for the version the user chose to skip.
    private static let skippedVersionKey = "skippedUpdateVersion"

    /// Interval between automatic checks (24 hours).
    private static let checkInterval: TimeInterval = 86_400

    /// How far macOS may move a scheduled check, so it can run while the Mac is idle.
    private static let checkTolerance: TimeInterval = 4 * 3_600

    /// The running app version (e.g. "1.2.0"); nil outside an app bundle, as with `swift run`.
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    private var scheduler: NSBackgroundActivityScheduler?
    private var isInstalling = false

    // MARK: - Public API

    /// Checks now unless a check succeeded recently, then about once a day while the app runs.
    func startAutomaticChecks() {
        checkIfNeeded()
        guard scheduler == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.schoofsebert.missionstrike.update-check")
        scheduler.interval = Self.checkInterval
        scheduler.tolerance = Self.checkTolerance
        scheduler.qualityOfService = .utility
        scheduler.repeats = true
        scheduler.schedule(Self.runScheduledCheck)
        self.scheduler = scheduler
    }

    /// Performs an immediate check (e.g. from "Check for Updates…" menu item). Unlike
    /// automatic checks, it also offers a version the user skipped.
    func checkNow() {
        check(userInitiated: true)
    }

    // MARK: - Private

    /// Called by the scheduler on a background queue.
    nonisolated private static func runScheduledCheck(
        _ completion: @escaping NSBackgroundActivityScheduler.CompletionHandler
    ) {
        Task { @MainActor in UpdateChecker.shared.checkIfNeeded() }
        completion(.finished)
    }

    /// Performs an automatic check unless one succeeded within the last day. The tolerance
    /// is subtracted so a scheduled check that runs a little early isn't skipped for a whole day.
    private func checkIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - lastCheck >= Self.checkInterval - Self.checkTolerance else {
            logger.debug("Skipping update check — last check was \(Int(now - lastCheck))s ago.")
            return
        }
        check(userInitiated: false)
    }

    private func check(userInitiated: Bool) {
        let window = UpdateWindowController.shared
        guard !isInstalling else {
            if userInitiated { window.bringToFront() }
            return
        }
        guard let currentVersion else {
            logger.info("Not running from an app bundle — skipping update check.")
            if userInitiated {
                window.showNotice(
                    title: "Updates Unavailable",
                    message: "Only an installed copy of MissionStrike can check for updates."
                )
            }
            return
        }

        Task {
            do {
                let release = try await fetchLatestRelease()
                // Only a successful check starts the cooldown, so an offline
                // launch retries next time instead of waiting a day.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                guard let latestVersion = ReleaseVersion.fromTag(release.tagName) else {
                    throw UpdateError.invalidReleaseTag(release.tagName)
                }
                guard !isInstalling else { return }

                if ReleaseVersion.isNewer(latestVersion, than: currentVersion) {
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey) == latestVersion
                    if userInitiated || !skipped {
                        logger.info("Update available: \(latestVersion) (current: \(currentVersion))")
                        showUpdateWindow(release: release, latestVersion: latestVersion, currentVersion: currentVersion)
                    } else {
                        logger.debug("Update \(latestVersion) was skipped by the user.")
                    }
                } else if userInitiated {
                    window.showNotice(
                        title: "You're Up to Date",
                        message: "MissionStrike \(currentVersion) is the latest version."
                    )
                } else {
                    logger.debug("Already on latest version (\(currentVersion)).")
                }
            } catch {
                logger.warning("Update check failed: \(error.localizedDescription)")
                if userInitiated {
                    window.showNotice(
                        title: "Update Check Failed",
                        message: "Check your internet connection or try again later. (\(error.localizedDescription))"
                    )
                }
            }
        }
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Update Window

    private func showUpdateWindow(release: GitHubRelease, latestVersion: String, currentVersion: String) {
        let offer = UpdateOffer(
            version: latestVersion,
            currentVersion: currentVersion,
            releaseNotes: release.body ?? "",
            releaseURL: release.htmlURL,
            downloadURL: release.assets.first { $0.name == "MissionStrike.app.zip" }?.browserDownloadURL
        )
        UpdateWindowController.shared.show(
            offer,
            install: { [weak self] offer in self?.performAutoUpdate(offer) },
            skip: { offer in
                UserDefaults.standard.set(offer.version, forKey: Self.skippedVersionKey)
                logger.info("Skipping update \(offer.version) until the user checks manually.")
            }
        )
    }

    // MARK: - Auto-Update

    /// Downloads, verifies and installs the release, then relaunches. The work runs off the
    /// main actor so the event tap keeps handling input; progress and failures are shown in
    /// the update window. The app only quits once the relaunch helper is running.
    private func performAutoUpdate(_ offer: UpdateOffer) {
        let window = UpdateWindowController.shared
        guard let downloadURL = offer.downloadURL else {
            logger.warning("No MissionStrike.app.zip asset in release.")
            window.showFailure("This release has no download for MissionStrike.")
            return
        }
        guard !isInstalling else { return }
        isInstalling = true
        window.setDownloadProgress(nil)

        let appURL = Bundle.main.bundleURL
        Task {
            defer { isInstalling = false }
            do {
                let replacement = try await UpdateInstaller.install(
                    from: downloadURL,
                    expectedVersion: offer.version,
                    replacing: appURL,
                    progress: { fraction in
                        Task { @MainActor in window.setDownloadProgress(fraction) }
                    },
                    status: { status in
                        await MainActor.run { window.setStatus(status) }
                    }
                )
                do {
                    try await UpdateInstaller.launchRelaunchHelper(for: appURL)
                } catch {
                    // Don't quit without a way back: put the running version back in place.
                    try await replacement.rollBack()
                    throw error
                }
                replacement.discardBackup()

                // Signal to the next launch that this is a self-update relaunch,
                // so AppDelegate can silently handle accessibility re-authorization.
                UserDefaults.standard.set(true, forKey: "pendingSelfUpdate")
                NSApplication.shared.terminate(nil)
            } catch {
                logger.error("Auto-update failed: \(error.localizedDescription)")
                switch error {
                case UpdateError.installedWithoutRelaunch, UpdateError.restoreFailed:
                    window.showFailure(error.localizedDescription)
                default:
                    window.showFailure("The update could not be installed: \(error.localizedDescription)")
                }
            }
        }
    }
}
