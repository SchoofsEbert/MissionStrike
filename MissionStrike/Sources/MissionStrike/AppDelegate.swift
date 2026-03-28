import Cocoa
import CoreGraphics
import ApplicationServices
import SwiftUI

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(x: 0, y: 0, width: newSize.width, height: newSize.height),
                  from: NSRect(x: 0, y: 0, width: self.size.width, height: self.size.height),
                  operation: .sourceOver,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UserDefaults.standard.register(defaults: ["showMenuBarIcon": true])

        UserDefaults.standard.addObserver(self, forKeyPath: "showMenuBarIcon", options: [.new, .initial], context: nil)

        // Request Accessibility permissions if needed
        checkAccessibilityPermissions()

        // Start Event Tap
        EventTapManager.shared.start()

        // Open settings on launch
        openSettingsWindow()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "showMenuBarIcon" {
            Task { @MainActor in
                self.setupMenuBarItem()
            }
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
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkAccessibilityPermissions() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if !accessEnabled {
            print("Access Not Enabled. Please enable in System Settings -> Privacy & Security -> Accessibility.")
            // Ideally, show an alert, but checking prompts the OS dialog automatically.
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            self.openSettingsWindow()
        }
        return true
    }
}
