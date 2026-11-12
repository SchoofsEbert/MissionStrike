import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "Snap")

/// Moves the window in front to where a snap shortcut asks.
///
/// Accessibility calls wait for the app to answer, so they run on a queue of their own: the
/// main thread, which runs the event tap, never waits on an app. Presses queue up in order.
final class WindowSnapper: @unchecked Sendable {
    static let shared = WindowSnapper()
    private init() {}

    private let queue = DispatchQueue(label: "io.github.schoofsebert.missionstrike.snap", qos: .userInteractive)
    /// Only touched on `queue`.
    private var lastSnap: SnapRecord?

    /// Reads what only the main thread may (the app in front, the screens), then snaps off it.
    @MainActor
    func snap(_ action: SnapAction) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let areas = Self.visibleAreas()
        queue.async {
            self.snap(action, pid: pid, areas: areas)
        }
    }

    /// Each screen's area without the menu bar and Dock, in AX space.
    @MainActor
    static func visibleAreas() -> [CGRect] {
        let height = ScreenCoordinates.mainDisplayHeight
        return NSScreen.screens.map { ScreenCoordinates.yFlipped($0.visibleFrame, mainDisplayHeight: height) }
    }

    private func snap(_ action: SnapAction, pid: pid_t, areas: [CGRect]) {
        let signpost = performanceSignposter.beginInterval("Snap")
        defer { performanceSignposter.endInterval("Snap", signpost) }

        let app = AXElement.application(pid)
        guard let window = app.element(kAXFocusedWindowAttribute) else {
            logger.info("Snap: the app in front has no focused window.")
            return
        }
        let values = window.attributes([kAXPositionAttribute, kAXSizeAttribute, Self.fullScreenAttribute])
        // A full-screen window has a Space of its own; moving it does nothing useful.
        guard values[Self.fullScreenAttribute] as? Bool != true,
              let current = AXElement.frame(from: values),
              let area = SnapLayout.area(for: current, in: areas) else {
            return
        }
        if action.isDisplayMove {
            guard let target = SnapLayout.frame(movingToDisplay: action, from: current, in: areas) else { return }
            _ = Self.move(window, of: app, to: target)
            lastSnap = nil
            return
        }
        let windowID = window.windowID
        let step = SnapLayout.nextStep(for: action, windowFrame: current, area: area, last: lastSnap, windowID: windowID)
        let target = SnapLayout.frame(for: action, step: step, in: area)
        let actual = Self.move(window, of: app, to: target) ?? target
        lastSnap = SnapRecord(action: action, step: step, windowID: windowID, frame: actual)
    }

    /// Sets the frame and returns the one the window took. Shrinks before moving, so the window
    /// isn't pushed back by a screen edge; sizes again when it couldn't grow where it was.
    static func move(_ window: AXElement, of app: AXElement, to frame: CGRect) -> CGRect? {
        // Chrome and Electron apps turn this on when they see an assistive app; while it's on,
        // they animate every change, and a move and a resize fight each other.
        let enhanced = app.attribute(enhancedUserInterfaceAttribute) as? Bool == true
        if enhanced {
            app.set(enhancedUserInterfaceAttribute, to: kCFBooleanFalse)
        }
        defer {
            if enhanced {
                app.set(enhancedUserInterfaceAttribute, to: kCFBooleanTrue)
            }
        }
        window.setSize(frame.size)
        window.setPosition(frame.origin)
        var actual = window.frame
        if let taken = actual, !SnapLayout.isClose(taken, frame) {
            window.setSize(frame.size)
            actual = window.frame
        }
        return actual
    }

    private static let fullScreenAttribute = "AXFullScreen"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
}
