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

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage {
        return NSImage(size: newSize, flipped: false) { rect in
            self.draw(in: rect,
                      from: NSRect(origin: .zero, size: self.size),
                      operation: .sourceOver,
                      fraction: 1.0)
            return true
        }
    }

    /// Returns a copy of the image with a small colored dot badge in the bottom-right corner.
    func withBadge(color: NSColor) -> NSImage {
        let badgeDiameter: CGFloat = 6
        return NSImage(size: self.size, flipped: false) { rect in
            self.draw(in: rect,
                      from: NSRect(origin: .zero, size: self.size),
                      operation: .sourceOver,
                      fraction: 1.0)
            let badgeRect = NSRect(
                x: rect.maxX - badgeDiameter - 1,
                y: 1,
                width: badgeDiameter,
                height: badgeDiameter
            )
            color.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var aboutWindow: NSWindow?
    private var kvoObservation: NSKeyValueObservation?
    private var accessibilityObserver: Any?
    private var eventTapObserver: Any?
    private var eventTapFailureObserver: Any?
    private var wasAccessibilityEnabled = AXIsProcessTrusted()

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
            "leftClickModifier": TriggerModifier.option.rawValue
        ])

        // Observe menu bar icon preference using modern block-based KVO (auto-removes on dealloc)
        kvoObservation = UserDefaults.standard.observe(\.showMenuBarIcon, options: [.new, .initial]) { [weak self] _, _ in
            Task { @MainActor in
                self?.setupMenuBarItem()
            }
        }

        // Observe accessibility permission changes via distributed notification
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAccessibilityChange()
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    logger.error("Notification authorization error: \(error.localizedDescription)")
                } else if !granted {
                    logger.info("User declined notification permissions — permission-loss alerts will not be shown.")
                }
            }
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

    private func handleAccessibilityChange() {
        let isNowEnabled = AXIsProcessTrusted()

        if wasAccessibilityEnabled && !isNowEnabled {
            // Permission was revoked
            logger.warning("Accessibility permissions revoked.")
            EventTapManager.shared.stop()
            sendPermissionLostNotification()
        } else if !wasAccessibilityEnabled && isNowEnabled {
            // Permission was granted
            logger.info("Accessibility permissions granted.")
            EventTapManager.shared.start()
        }

        wasAccessibilityEnabled = isNowEnabled
        updateMenuBarIconState()
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
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                logger.error("Failed to deliver permission-loss notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBarItem() {
        let showIcon = UserDefaults.standard.bool(forKey: "showMenuBarIcon")

        if showIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = statusItem?.button {
                    button.toolTip = "MissionStrike"
                }

                let menu = NSMenu()
                menu.addItem(NSMenuItem(
                    title: "About MissionStrike",
                    action: #selector(openAboutWindow),
                    keyEquivalent: ""
                ))
                menu.addItem(NSMenuItem(
                    title: "Check for Updates…",
                    action: #selector(checkForUpdates),
                    keyEquivalent: ""
                ))
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem(
                    title: "Settings...",
                    action: #selector(openSettingsWindow),
                    keyEquivalent: ","
                ))
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem(
                    title: "Quit MissionStrike",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q"
                ))
                statusItem?.menu = menu
            }
            updateMenuBarIconState()
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    /// Updates the menu bar icon to reflect the current active/inactive state.
    /// Active (green dot): event tap running + accessibility enabled.
    /// Inactive (orange dot): event tap not running or accessibility denied.
    private func updateMenuBarIconState() {
        guard let button = statusItem?.button else { return }

        let isActive = EventTapManager.shared.isRunning && AXIsProcessTrusted()

        if let originalImage = NSApplication.shared.applicationIconImage {
            let resized = originalImage.resized(to: NSSize(width: 18, height: 18))
            let icon: NSImage
            if isActive {
                icon = resized
            } else {
                icon = resized.withBadge(color: .systemOrange)
            }
            icon.isTemplate = false
            button.image = icon
        } else {
            button.title = isActive ? "MS" : "MS⚠"
        }

        button.toolTip = isActive
            ? "MissionStrike: Active"
            : "MissionStrike: Inactive — check Accessibility permissions"
    }

    private func openOnboardingWindow() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.openSettingsWindow()
            }
            let hostingController = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
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
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
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
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            logger.warning("Accessibility not enabled. Please enable in System Settings -> Privacy & Security -> Accessibility.")
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
