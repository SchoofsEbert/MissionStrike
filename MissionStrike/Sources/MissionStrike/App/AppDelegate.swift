import Cocoa
import CoreGraphics
import ApplicationServices
import SwiftUI
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "AppDelegate")

extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        return bool(forKey: "showMenuBarIcon")
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var aboutWindow: NSWindow?
    private var kvoObservation: NSKeyValueObservation?
    private var accessibilityObserver: Any?
    private var eventTapObserver: Any?
    private var eventTapFailureObserver: Any?
    private var wasAccessibilityEnabled = AXIsProcessTrusted()
    private var accessibilityRetryTask: Task<Void, Never>?

    /// Prevents App Nap from throttling the event tap run loop.
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Prevent App Nap — the event tap must respond to clicks in real time,
        // even when MissionStrike has no visible windows.
        // Note: .userInitiated alone disables App Nap without preventing system sleep,
        // so there is no battery impact on laptops.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Event tap must remain responsive for Mission Control clicks"
        )

        // Register all UserDefaults defaults in one place
        UserDefaults.standard.register(defaults: [
            "showMenuBarIcon": true,
            "enableSpaceClosing": true,
            "enableMiddleClick": true,
            "enableContextMenu": true,
            "enableKeyboardShortcuts": true,
            "showHoverBadge": true,
            "leftClickModifier": TriggerModifier.option.rawValue
        ])

        // Observe menu bar icon preference using modern block-based KVO (auto-removes on dealloc)
        kvoObservation = UserDefaults.standard.observe(\.showMenuBarIcon, options: [.new, .initial]) { [weak self] _, _ in
            Task { @MainActor in
                self?.setupMenuBarItem()
            }
        }

        // Observe accessibility permission changes via distributed notification.
        // On recent macOS versions TCC can lag the notification, so we also retry.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleAccessibilitySync()
            }
        }

        // Observe event tap state changes to update the menu bar icon
        eventTapObserver = NotificationCenter.default.addObserver(
            forName: .eventTapStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuBarIconState()
            }
        }

        // Observe event tap creation failures to show a user-facing alert
        eventTapFailureObserver = NotificationCenter.default.addObserver(
            forName: .eventTapCreationFailed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showEventTapFailureAlert()
            }
        }

        // Request notification permission for permission-loss alerts.
        // UNUserNotificationCenter requires a proper .app bundle; skip when running via `swift run`.
        if Bundle.main.bundleIdentifier != nil {
            requestNotificationAuthorizationIfNeeded()
        } else {
            logger.info("No bundle identifier — skipping notification permission request (running outside .app bundle).")
        }

        // Request Accessibility permissions if needed
        checkAccessibilityPermissions()

        // Start Event Tap
        EventTapManager.shared.start()

        // Only show onboarding on first launch, not on subsequent auto-starts (e.g., Login Items)
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            openOnboardingWindow()
        }

        // Check for updates in the background (once per 24 hours)
        UpdateChecker.shared.checkIfNeeded()
    }

    // MARK: - Accessibility State

    /// Key used to remember that accessibility was previously granted.
    private static let accessibilityWasGrantedKey = "accessibilityWasGranted"

    /// Sync immediately, then retry at fixed offsets while TCC catches up.
    private func scheduleAccessibilitySync() {
        accessibilityRetryTask?.cancel()
        accessibilityRetryTask = AccessibilityTrustRetry.schedule { [weak self] in
            self?.syncAccessibilityState()
            // Stop early once trusted and the tap is running.
            if AXIsProcessTrusted(), EventTapManager.shared.isRunning {
                self?.accessibilityRetryTask?.cancel()
            }
        }
    }

    private func syncAccessibilityState() {
        let isNowEnabled = AXIsProcessTrusted()

        if wasAccessibilityEnabled && !isNowEnabled {
            // Permission was revoked
            logger.warning("Accessibility permissions revoked.")
            EventTapManager.shared.stop()
            UserDefaults.standard.set(false, forKey: Self.accessibilityWasGrantedKey)
            sendPermissionLostNotification()
        } else if !wasAccessibilityEnabled && isNowEnabled {
            // Permission was granted
            logger.info("Accessibility permissions granted.")
            UserDefaults.standard.set(true, forKey: Self.accessibilityWasGrantedKey)
            EventTapManager.shared.start()
        } else if isNowEnabled && !EventTapManager.shared.isRunning {
            // Trusted but tap never started (e.g. grant raced the first check).
            logger.info("Accessibility trusted — starting event tap.")
            EventTapManager.shared.start()
        }

        wasAccessibilityEnabled = isNowEnabled
        updateMenuBarIconState()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Catch grants that happened while we were inactive / notification was missed.
        if !EventTapManager.shared.isRunning {
            scheduleAccessibilitySync()
        }
    }

    /// Asks for notification permission only while the user hasn't decided yet. Once
    /// notifications are off, asking again fails with "not allowed" on every launch.
    private func requestNotificationAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .notDetermined else {
                if status == .denied {
                    logger.info("Notifications are off — permission-loss alerts will not be shown.")
                }
                return
            }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if !granted {
                    logger.info("User declined notification permissions — permission-loss alerts will not be shown.")
                }
            } catch {
                logger.warning("Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendPermissionLostNotification() {
        guard Bundle.main.bundleIdentifier != nil else {
            logger.warning("Cannot deliver notification — no bundle identifier.")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "MissionStrike Disabled"
        content.body = "Accessibility permissions were revoked. MissionStrike cannot close windows "
            + "until permissions are restored. Re-enable in System Settings → Privacy & Security → Accessibility."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "com.vibecoded.missionstrike.permissionLost", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            // The orange menu bar icon still shows the state when notifications are off.
            guard await center.notificationSettings().authorizationStatus == .authorized else {
                logger.info("Notifications are off — skipping permission-loss notification.")
                return
            }
            do {
                try await center.add(request)
            } catch {
                logger.error("Failed to deliver permission-loss notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBarItem() {
        StatusBarController.shared.setVisible(UserDefaults.standard.bool(forKey: "showMenuBarIcon"), delegate: self)
    }

    private func updateMenuBarIconState() {
        StatusBarController.shared.refresh()
    }

    func openOnboardingWindow() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.openSettingsWindow()
            }
            let hostingController = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Welcome to MissionStrike"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            self.onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func checkForUpdates() {
        UpdateChecker.shared.checkNow()
    }

    @objc func openAboutWindow() {
        if aboutWindow == nil {
            let view = AboutView()
            let hostingController = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "About MissionStrike"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            self.aboutWindow = window
        }

        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func openSettingsWindow() {
        if settingsWindow == nil {
            let view = SettingsView()
            let hostingController = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "MissionStrike Settings"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func checkAccessibilityPermissions() {
        let accessEnabled = AXIsProcessTrusted()
        let previouslyGranted = UserDefaults.standard.bool(forKey: Self.accessibilityWasGrantedKey)
        let isSelfUpdateRelaunch = UserDefaults.standard.bool(forKey: "pendingSelfUpdate")

        // Always clear the self-update flag so it doesn't fire again
        if isSelfUpdateRelaunch {
            UserDefaults.standard.removeObject(forKey: "pendingSelfUpdate")
        }

        if accessEnabled {
            // All good — remember the grant
            UserDefaults.standard.set(true, forKey: Self.accessibilityWasGrantedKey)
            return
        }

        if isSelfUpdateRelaunch || previouslyGranted {
            // Accessibility was granted before but invalidated by the update.
            // Reset the stale TCC entry and prompt directly — no intermediate alert
            // needed when we know exactly what happened.
            logger.info("Accessibility invalidated after update — resetting TCC and re-prompting.")
            resetTCCEntry()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                _ = AXIsProcessTrustedWithOptions(options)
            }
        } else {
            // First time — use the standard system prompt
            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options)
            logger.warning("Accessibility not enabled. Prompting user.")
        }
    }

    // MARK: - TCC Reset

    /// Runs `tccutil reset Accessibility <bundleID>` to clear the stale TCC entry
    /// left over from the previous binary signature. This allows the standard
    /// system prompt to work without the user manually removing the app first.
    private func resetTCCEntry() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            logger.info("TCC entry reset for \(bundleID) (exit code \(process.terminationStatus)).")
        } catch {
            logger.warning("Failed to reset TCC entry: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Tap Failure Alert

    /// Shows a user-visible alert when `CGEvent.tapCreate` fails.
    /// This can happen on Apple Silicon Macs with certain security configurations
    /// (e.g., MDM-managed devices) even when Accessibility permissions are granted.
    ///
    /// If Accessibility is not yet granted, the failure is expected and the
    /// onboarding / permission flow will guide the user. Once permissions are
    /// enabled, `handleAccessibilityChange()` retries `start()` automatically,
    /// so we only surface this alert for the true edge case.
    private func showEventTapFailureAlert() {
        // Don't alarm the user during onboarding — the tap is expected to fail
        // until Accessibility permissions are granted.
        guard AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "MissionStrike Could Not Start"
        alert.informativeText = """
            The system refused to create an event tap. This can happen even with \
            Accessibility permissions enabled — for example on MDM-managed Macs or \
            certain Apple Silicon security configurations.

            Troubleshooting steps:
            1. Open System Settings → Privacy & Security → Accessibility.
            2. Remove MissionStrike from the list, then re-add it.
            3. Restart your Mac and try again.
            4. If your Mac is managed by an organization, contact your IT administrator \
            — a configuration profile may be blocking input monitoring.
            """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")

        NSApp.activate()
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Open Accessibility preferences pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            // Retry starting the event tap
            EventTapManager.shared.start()
        case .alertThirdButtonReturn:
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }
}
