import AppKit
import CoreGraphics

/// Middle-click on a running app's Dock icon quits it, like closing a browser tab;
/// with ⌥ held it closes the app's windows instead. Works with or without Mission Control.
/// `TapRouter` decides from `DockIconCache` whether a click is the Dock's; this acts on it.
enum DockMiddleClick {
    /// Points to try in AX space. Quartz location matches AX space; the flipped AppKit
    /// pointer location covers Mission Control's coordinate quirks on macOS 27.
    static func candidates(location: CGPoint, pointer: CGPoint) -> [CGPoint] {
        [location, ScreenCoordinates.yFlipped(pointer)]
    }

    /// Asks the Dock which running app's icon is under the click, then quits the app or closes
    /// its windows. False when the click wasn't on a running app's icon.
    @MainActor
    @discardableResult
    static func perform(at candidates: [CGPoint], closeWindowsOnly: Bool) -> Bool {
        defer { DockIconCache.shared.scheduleRefresh(after: .milliseconds(500)) }
        guard let hit = DockHitTester.runningApp(at: candidates) else {
            return false
        }
        if closeWindowsOnly {
            MissionControlManager.shared.closeAllWindows(forPID: hit.app.processIdentifier)
        } else {
            hit.app.terminate()
        }
        let icon = ScreenCoordinates.yFlipped(hit.iconFrame)
        CloseEffect.play(at: NSPoint(x: icon.midX, y: icon.midY))
        return true
    }
}
