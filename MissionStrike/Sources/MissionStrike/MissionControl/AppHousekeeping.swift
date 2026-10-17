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
            // Nil (the app can't be asked) is not the same as no windows.
            return AXElement.application(app.processIdentifier).windows?.isEmpty == true
        }
    }
}
