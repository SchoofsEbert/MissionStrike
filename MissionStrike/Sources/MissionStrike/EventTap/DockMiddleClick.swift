import AppKit
import CoreGraphics

/// Middle-click on a running app's Dock icon quits it, like closing a browser tab;
/// with ⌥ held it closes the app's windows instead. Works with or without Mission Control.
/// Returns true when the click was handled and must be swallowed.
func handleDockMiddleClick(_ event: CGEvent) -> Bool {
    guard event.getIntegerValueField(.mouseEventButtonNumber) == 2,
          UserDefaults.standard.bool(forKey: "enableDockMiddleClick") else {
        return false
    }
    // Quartz location matches AX space; the flipped AppKit location covers Mission
    // Control's coordinate quirks on macOS 27.
    let candidates = [event.location, ScreenCoordinates.yFlipped(NSEvent.mouseLocation)]
    guard let hit = DockHitTester.runningApp(at: candidates) else {
        return false
    }

    let closeWindowsOnly = event.flags.contains(.maskAlternate)
    Task { @MainActor in
        let icon = ScreenCoordinates.yFlipped(hit.iconFrame)
        CloseEffect.play(at: NSPoint(x: icon.midX, y: icon.midY))
        if closeWindowsOnly {
            MissionControlManager.shared.closeAllWindows(forPID: hit.app.processIdentifier)
        } else {
            hit.app.terminate()
        }
    }
    return true
}
