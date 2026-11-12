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
    /// The last snap of each window, so cycling survives switching windows. Only touched on `queue`.
    private var lastSnaps: [CGWindowID: SnapRecord] = [:]
    private static let maxRecords = 64

    /// Reads what only the main thread may (the app in front, the screens), then snaps off it.
    @MainActor
    func snap(_ action: SnapAction) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let areas = Self.visibleAreas()
        // Accessibility calls on our own windows run AppKit on the calling thread, which must
        // be the main one; AppKit can place them directly.
        if pid == ProcessInfo.processInfo.processIdentifier {
            Self.snapOwnWindow(action, areas: areas)
            return
        }
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

    @MainActor
    private static func snapOwnWindow(_ action: SnapAction, areas: [CGRect]) {
        guard let window = NSApp.keyWindow, window.styleMask.contains(.resizable) else { return }
        let height = ScreenCoordinates.mainDisplayHeight
        let current = ScreenCoordinates.yFlipped(window.frame, mainDisplayHeight: height)
        guard let plan = SnapLayout.plan(action, windowFrame: current, areas: areas, last: nil, windowID: nil) else { return }
        window.setFrame(ScreenCoordinates.yFlipped(plan.frame, mainDisplayHeight: height), display: true)
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
              let current = AXElement.frame(from: values) else {
            return
        }
        let windowID = window.windowID
        let last = windowID.flatMap { lastSnaps[$0] }
        guard let plan = SnapLayout.plan(action, windowFrame: current, areas: areas, last: last, windowID: windowID) else {
            return
        }
        let taken = Self.move(window, of: app, to: plan.frame, action: action, area: plan.area) ?? plan.frame
        guard let windowID else { return }
        if lastSnaps.count >= Self.maxRecords {
            lastSnaps.removeAll()
        }
        lastSnaps[windowID] = action.isDisplayMove
            ? nil
            : SnapRecord(action: action, step: plan.step, windowID: windowID, frame: taken)
    }

    /// Sets the frame and returns the one the window took. Shrinks before moving, so the window
    /// isn't pushed back by a screen edge; sizes again when it couldn't grow where it was, and
    /// moves again when the size it took leaves it off the edge its action hugs.
    static func move(_ window: AXElement, of app: AXElement, to frame: CGRect, action: SnapAction, area: CGRect) -> CGRect? {
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
        guard var taken = window.frame, !SnapLayout.isClose(taken, frame) else { return frame }
        if !SnapLayout.isClose(CGRect(origin: taken.origin, size: frame.size), frame) {
            window.setPosition(frame.origin)
        }
        window.setSize(frame.size)
        taken = window.frame ?? taken
        let anchored = SnapLayout.anchored(taken, for: action, target: frame, in: area)
        guard anchored.origin != taken.origin else { return taken }
        window.setPosition(anchored.origin)
        return window.frame ?? anchored
    }

    private static let fullScreenAttribute = "AXFullScreen"
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
}
