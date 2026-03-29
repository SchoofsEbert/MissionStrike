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
        case assets
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
        ) as? String ?? "2.1.0"
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
                        release: release
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

    private func showUpdateAlert(latestVersion: String, release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "MissionStrike \(latestVersion) is available "
            + "(you're on \(currentVersion))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")

        if let icon = NSApplication.shared.applicationIconImage {
            alert.icon = icon
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Auto-update: find the .zip asset and install it
            if let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                performAutoUpdate(downloadURL: asset.browserDownloadURL, version: latestVersion)
            } else {
                logger.warning("No .zip asset found in release — falling back to browser.")
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    // MARK: - Auto-Update

    /// Downloads the release zip, extracts it, removes quarantine, replaces
    /// the running app bundle, and relaunches. Falls back to opening the
    /// release page in the browser on any failure.
    private func performAutoUpdate(downloadURL: URL, version: String) {
        // Show a progress window
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = "Updating MissionStrike…"
        progressWindow.center()

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)

        let label = NSTextField(labelWithString: "Downloading MissionStrike \(version)…")
        label.alignment = .center

        let stack = NSStackView(views: [label, progressIndicator])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        progressWindow.contentView = stack

        progressWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()

        Task {
            do {
                let appPath = try await downloadAndInstall(
                    downloadURL: downloadURL,
                    progressLabel: label
                )
                progressWindow.close()
                relaunch(appPath: appPath)
            } catch {
                progressWindow.close()
                logger.error("Auto-update failed: \(error.localizedDescription)")

                let errorAlert = NSAlert()
                errorAlert.messageText = "Update Failed"
                errorAlert.informativeText = "The automatic update could not be completed: "
                    + "\(error.localizedDescription)\n\n"
                    + "Would you like to download the update manually?"
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "Open Download Page")
                errorAlert.addButton(withTitle: "Cancel")
                if errorAlert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
        }
    }

    /// Downloads the zip, extracts, removes quarantine, and replaces the app bundle.
    /// Returns the path to the newly installed app.
    private func downloadAndInstall(
        downloadURL: URL,
        progressLabel: NSTextField
    ) async throws -> String {
        let fileManager = FileManager.default
        let tmpDir = fileManager.temporaryDirectory
            .appendingPathComponent("MissionStrike-update-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // 1. Download the zip
        let zipPath = tmpDir.appendingPathComponent("MissionStrike.app.zip")
        let (downloadedURL, response) = try await URLSession.shared.download(for: URLRequest(url: downloadURL))
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        try fileManager.moveItem(at: downloadedURL, to: zipPath)

        // 2. Extract the zip
        await MainActor.run { progressLabel.stringValue = "Extracting…" }
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-qo", zipPath.path, "-d", tmpDir.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        guard unzipProcess.terminationStatus == 0 else {
            throw NSError(
                domain: "UpdateChecker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract update archive."]
            )
        }

        let extractedApp = tmpDir.appendingPathComponent("MissionStrike.app")
        guard fileManager.fileExists(atPath: extractedApp.path) else {
            throw NSError(
                domain: "UpdateChecker", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Extracted archive did not contain MissionStrike.app."]
            )
        }

        // 3. Remove macOS quarantine flag
        await MainActor.run { progressLabel.stringValue = "Removing quarantine…" }
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-cr", extractedApp.path]
        try xattrProcess.run()
        xattrProcess.waitUntilExit()

        // 4. Replace the current app bundle
        await MainActor.run { progressLabel.stringValue = "Installing…" }
        let currentAppURL = Bundle.main.bundleURL
        let installDir = currentAppURL.deletingLastPathComponent()
        let installedAppURL = installDir.appendingPathComponent("MissionStrike.app")

        // Move old app to trash (recoverable) and put the new one in place
        if fileManager.fileExists(atPath: installedAppURL.path) {
            try fileManager.trashItem(at: installedAppURL, resultingItemURL: nil)
        }
        try fileManager.moveItem(at: extractedApp, to: installedAppURL)

        // Clean up temp directory (best-effort)
        try? fileManager.removeItem(at: tmpDir)

        return installedAppURL.path
    }

    /// Spawns a detached process to relaunch the app after the current process exits.
    private func relaunch(appPath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Shell snippet: wait for current PID to exit, then open the new app.
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            open "\(appPath)"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()

        // Quit the current instance so the relaunch script can proceed
        NSApplication.shared.terminate(nil)
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
