import AppKit
import ApplicationServices

/// App-wide tidy-up actions offered from the Mission Control right-click menu.
@MainActor
enum AppHousekeeping {
    /// Apps never offered for the background menu's list of apps with no windows: Finder normally has no windows
    /// and quitting it only makes it relaunch.
    private static let keptRunning: Set<String> = ["com.apple.finder"]

    /// Hides every other regular app, like ⌥⌘H.
    static func hideOthers(except pid: pid_t) {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != pid && !app.isHidden {
            app.hide()
        }
    }

    /// Regular apps that are running without any window, minimized ones included.
    static func appsWithoutWindows() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  !keptRunning.contains(app.bundleIdentifier ?? "") else {
                return false
            }
            return windowCount(of: app.processIdentifier) == 0
        }
    }

    /// Number of windows the app reports through Accessibility; nil if it can't be asked.
    private static func windowCount(of pid: pid_t) -> Int? {
        var windowsRef: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        return windows.count
    }
}
