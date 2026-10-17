import AppKit
import CoreGraphics

/// Middle-click on a running app's Dock icon quits it, like closing a browser tab;
/// with ⌥ held it closes the app's windows instead. Works with or without Mission Control.
enum DockMiddleClick {
    /// What a middle-click means for the Dock, from cheap state only: this runs in the event
    /// tap. `.runningApp` clicks are swallowed and handled with `perform` after the callback;
    /// for `.maybe` the click goes its usual way and `perform` asks the Dock afterwards.
    static func verdict(for event: CGEvent) -> DockSnapshot.Verdict {
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2,
              UserDefaults.standard.bool(forKey: "enableDockMiddleClick") else {
            return .elsewhere
        }
        let candidates = candidates(for: event)
        // The tap's run loop source lives on the main run loop.
        return MainActor.assumeIsolated { DockIconCache.shared.verdict(at: candidates) }
    }

    /// Points to try in AX space. Quartz location matches AX space; the flipped AppKit
    /// location covers Mission Control's coordinate quirks on macOS 27.
    static func candidates(for event: CGEvent) -> [CGPoint] {
        [event.location, ScreenCoordinates.yFlipped(NSEvent.mouseLocation)]
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
