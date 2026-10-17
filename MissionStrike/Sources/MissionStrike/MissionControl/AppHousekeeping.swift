import AppKit
import ApplicationServices
import os

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
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.processIdentifier != ownPID
                && !keptRunning.contains(app.bundleIdentifier ?? "")
        }

        // One copy of the window list settles most apps without asking them: an app showing a
        // normal window has one, and an app that owns no window anywhere has none.
        let windows = WindowList.ownership()
        var windowless = candidates.filter { !windows.owning.contains($0.processIdentifier) }
        let undecided = candidates.filter {
            windows.owning.contains($0.processIdentifier) && !windows.showing.contains($0.processIdentifier)
        }

        // Ask the rest through Accessibility, all at once: each may take up to the messaging
        // timeout to answer, which one after another adds up while the menu waits.
        let counts = windowCounts(of: undecided.map(\.processIdentifier))
        windowless += zip(undecided, counts).filter { $0.1 == 0 }.map(\.0)
        return windowless
    }

    /// Number of windows each app reports through Accessibility; nil where it can't be asked.
    nonisolated private static func windowCounts(of pids: [pid_t]) -> [Int?] {
        let counts = OSAllocatedUnfairLock(initialState: [Int?](repeating: nil, count: pids.count))
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let count = AXElement.application(pids[index]).windows?.count
            counts.withLock { $0[index] = count }
        }
        return counts.withLock { $0 }
    }
}
