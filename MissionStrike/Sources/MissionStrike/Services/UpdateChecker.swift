import Foundation
import Cocoa
import os.log

private let logger = Logger(
    subsystem: "com.vibecoded.missionstrike",
    category: "UpdateChecker"
)

/// Decoded payload from the GitHub Releases API.
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// Checks for new releases by polling the GitHub Releases API.
/// No external dependencies — compares semantic version tags against
/// the running app version and presents an alert if an update is available.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private static let repoOwner = "SchoofsEbert"
    private static let repoName = "MissionStrike"
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
    )!

    /// UserDefaults key for the last automatic check timestamp.
    private static let lastCheckKey = "lastUpdateCheckTimestamp"

    /// Minimum interval between automatic checks (24 hours).
    private static let checkInterval: TimeInterval = 86_400

    /// The running app version (e.g. "1.2.0").
    private let currentVersion: String = {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.2.0"
    }()

    // MARK: - Public API

    /// Performs an automatic background check, respecting the 24-hour cooldown.
    func checkIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - lastCheck >= Self.checkInterval else {
            logger.debug("Skipping update check — last check was \(Int(now - lastCheck))s ago.")
            return
        }
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        check(userInitiated: false)
    }

    /// Performs an immediate check (e.g. from "Check for Updates…" menu item).
    func checkNow() {
        check(userInitiated: true)
    }

    // MARK: - Private

    private func check(userInitiated: Bool) {
        Task {
            do {
                let release = try await fetchLatestRelease()
                let latestVersion = release.tagName
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "v", with: "")

                if isVersion(latestVersion, newerThan: currentVersion) {
                    logger.info("Update available: \(latestVersion) (current: \(self.currentVersion))")
                    showUpdateAlert(
                        latestVersion: latestVersion,
                        releaseURL: release.htmlURL
                    )
                } else if userInitiated {
                    showUpToDateAlert()
                } else {
                    logger.debug("Already on latest version (\(self.currentVersion)).")
                }
            } catch {
                logger.warning("Update check failed: \(error.localizedDescription)")
                if userInitiated {
                    showErrorAlert(error: error)
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

    // MARK: - Version Comparison

    /// Simple semantic version comparison (e.g. "1.3.0" > "1.2.0").
    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        for index in 0..<max(remoteParts.count, localParts.count) {
            let remoteVal = index < remoteParts.count ? remoteParts[index] : 0
            let localVal = index < localParts.count ? localParts[index] : 0
            if remoteVal > localVal { return true }
            if remoteVal < localVal { return false }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAlert(latestVersion: String, releaseURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "MissionStrike \(latestVersion) is available "
            + "(you're on \(currentVersion)). "
            + "Would you like to open the download page?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if let icon = NSApplication.shared.applicationIconImage {
            alert.icon = icon
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "MissionStrike \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if let icon = NSApplication.shared.applicationIconImage {
            alert.icon = icon
        }

        alert.runModal()
    }

    private func showErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not check for updates. "
            + "Please check your internet connection or try again later.\n\n"
            + "(\(error.localizedDescription))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
