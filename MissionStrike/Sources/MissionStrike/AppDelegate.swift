import Cocoa
import CoreGraphics
import ApplicationServices
import SwiftUI
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
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    private var kvoObservation: NSKeyValueObservation?

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

    private func setupMenuBarItem() {
        let showIcon = UserDefaults.standard.bool(forKey: "showMenuBarIcon")

        if showIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = statusItem?.button {
                    if let originalImage = NSApplication.shared.applicationIconImage {
                        let resizedImage = originalImage.resized(to: NSSize(width: 18, height: 18))
                        resizedImage.isTemplate = false
                        button.image = resizedImage
                    } else {
                        button.title = "MS"
                    }
                    button.toolTip = "MissionStrike: Settings..."
                }

                let menu = NSMenu()
                menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ","))
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem(title: "Quit MissionStrike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
                statusItem?.menu = menu
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
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
