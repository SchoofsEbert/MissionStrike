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
    private var kvoObservation: NSKeyValueObservation?
    private var accessibilityObserver: Any?
    private var eventTapObserver: Any?
    private var wasAccessibilityEnabled = AXIsProcessTrusted()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Register all UserDefaults defaults in one place
        UserDefaults.standard.register(defaults: [
            "showMenuBarIcon": true,
            "enableSpaceClosing": true
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

        // Request notification permission for permission-loss alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                logger.info("User declined notification permissions — permission-loss alerts will not be shown.")
            }
        }

        // Request Accessibility permissions if needed
        checkAccessibilityPermissions()

        // Start Event Tap
        EventTapManager.shared.start()

        // Only show settings window on first launch, not on subsequent auto-starts (e.g., Login Items)
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            openSettingsWindow()
        }
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
        let content = UNMutableNotificationContent()
        content.title = "MissionStrike Disabled"
        content.body = "Accessibility permissions were revoked. MissionStrike cannot close windows until permissions are restored. Re-enable in System Settings → Privacy & Security → Accessibility."
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
                menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ","))
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem(title: "Quit MissionStrike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    @objc func openSettingsWindow() {
        if settingsWindow == nil {
            let view = SettingsView()
            let hostingController = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }
}
