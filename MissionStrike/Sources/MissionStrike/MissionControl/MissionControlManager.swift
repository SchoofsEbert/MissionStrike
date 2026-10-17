import Cocoa
import CoreGraphics
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "MissionControl")

// MARK: - Mission Control Manager

@MainActor
class MissionControlManager {
    static let shared = MissionControlManager()
    private init() {}

    /// Resolves a swallowed middle-click or modifier-click once the tap callback has returned,
    /// and acts on what it hit.
    func handleClick(_ action: MouseAction, input: String, at pointer: CGPoint) {
        let resolution = MissionControlHitTester.resolve(clickPoint: pointer)
        // Mission Control may have closed while the click waited to be resolved;
        // acting then would close a window the user can no longer see being targeted.
        if let resolution, MissionControlSession.isActive(maxAge: .zero) {
            perform(resolution: resolution, action: action)
        }
        // Recorded after acting, so the bookkeeping never holds up the close.
        Diagnostics.shared.record(input, at: pointer, resolution: resolution)
    }

    /// Performs a pre-resolved hit.
    func perform(resolution: MissionControlHitTester.Resolution, action: MouseAction) {
        let signpost = performanceSignposter.beginInterval("Perform")
        defer {
            performanceSignposter.endInterval("Perform", signpost)
            HoverBadgeController.shared.layoutMayHaveChanged()
        }
        switch resolution.target {
        case .removeDesktop(let button):
            guard action == .close || action == .closeAll else { return }
            removeDesktop(button)

        case .window(let pid, let ownerName, let windowID):
            switch action {
            case .close:
                logger.debug("Closing wid \(windowID) (\(ownerName), pid \(pid)).")
                closeWindowByWindowID(pid: pid, targetWindowID: windowID, resolution: resolution)
            case .closeAll:
                closeAllWindows(forPID: pid, anchor: resolution.feedbackAnchor)
            case .minimize:
                minimizeWindow(pid: pid, windowID: windowID)
            }

        case .legacyAXWindow(let window):
            switch action {
            case .close:
                closeLegacyAXWindow(window, resolution: resolution)
            case .closeAll:
                if let pid = window.pid {
                    closeAllWindows(forPID: pid, anchor: resolution.feedbackAnchor)
                }
            case .minimize:
                minimize(window)
            }
        }
    }

    /// Whether Spaces may be closed at all; every way of closing one (click, ⌘W, menu) checks it.
    static var isSpaceClosingEnabled: Bool {
        SettingsStore.shared.current.enableSpaceClosing
    }

    /// Removes a Space via its Spaces Bar button, unless Space closing is turned off.
    func removeDesktop(_ button: AXElement) {
        guard Self.isSpaceClosingEnabled else {
            logger.info("Space close skipped — enableSpaceClosing is off.")
            return
        }
        let result = button.perform("AXRemoveDesktop")
        if result == .success {
            MissionControlSession.current?.forgetSpaces()
            HoverBadgeController.shared.layoutMayHaveChanged()
            CloseEffect.play(at: NSEvent.mouseLocation)
            logger.debug("Closed Space via AXRemoveDesktop.")
        } else {
            logger.warning("AXRemoveDesktop failed with error: \(result.rawValue)")
        }
    }

    /// Owning app of a window hit; nil for Spaces or when the window is gone.
    func pid(for resolution: MissionControlHitTester.Resolution) -> pid_t? {
        switch resolution.target {
        case .removeDesktop:
            return nil
        case .window(let pid, _, _):
            return pid
        case .legacyAXWindow(let window):
            return window.pid
        }
    }

    // MARK: - Window actions

    private func closeWindowByWindowID(pid: Int32, targetWindowID: CGWindowID, resolution: MissionControlHitTester.Resolution) {
        guard let window = axWindow(pid: pid, windowID: targetWindowID) else {
            logger.warning("Could not find AX window for CGWindowID \(targetWindowID).")
            return
        }
        guard pressCloseButton(of: window) else { return }
        logger.debug("Pressed close on CGWindow \(targetWindowID), PID \(pid).")
        watch([PendingClose(window: window, pid: pid, thumbnail: resolution.thumbnailFrame)], anchor: resolution.feedbackAnchor)
    }

    private func minimizeWindow(pid: Int32, windowID: CGWindowID) {
        guard let window = axWindow(pid: pid, windowID: windowID) else {
            logger.warning("Could not find window \(windowID) to minimize.")
            return
        }
        minimize(window)
    }

    /// Closes every window of the app, optionally keeping one ("Close Other Windows"). Feedback
    /// for windows without a known thumbnail goes to `anchor` (AppKit screen coordinates).
    func closeAllWindows(forPID pid: pid_t, except keptWindowID: CGWindowID? = nil, anchor: CGRect?) {
        guard let windows = AXElement.application(pid).windows else {
            logger.warning("Could not enumerate windows for close-all on PID \(pid).")
            return
        }
        var pressed: [PendingClose] = []
        for window in windows {
            if let keptWindowID, window.windowID == keptWindowID {
                continue
            }
            if pressCloseButton(of: window) {
                pressed.append(PendingClose(window: window, pid: pid))
            }
        }
        logger.debug("Pressed close on \(pressed.count)/\(windows.count) windows for PID \(pid).")
        watch(pressed, anchor: anchor)
    }

    // MARK: - AX window helpers

    /// The app's AX window with the given CGWindowID, if it still exists.
    private func axWindow(pid: pid_t, windowID: CGWindowID) -> AXElement? {
        AXElement.application(pid).windows?.first { $0.windowID == windowID }
    }

    /// Presses the window's close button; false when it has none or the press fails.
    @discardableResult
    private func pressCloseButton(of window: AXElement) -> Bool {
        guard let closeButton = window.closeButton else {
            logger.warning("Window has no close button.")
            return false
        }
        return press(closeButton)
    }

    private func press(_ closeButton: AXElement) -> Bool {
        let result = closeButton.perform(kAXPressAction)
        if result != .success {
            logger.warning("AXPress on close button failed: \(result.rawValue)")
        }
        return result == .success
    }

    private func minimize(_ window: AXElement) {
        let result = window.set(kAXMinimizedAttribute, to: kCFBooleanTrue)
        if result == .success {
            logger.debug("Minimized window.")
        } else {
            logger.warning("AXMinimized failed: \(result.rawValue)")
        }
    }

    // MARK: - Legacy windows

    private func closeLegacyAXWindow(_ window: AXElement, resolution: MissionControlHitTester.Resolution) {
        var closed = false
        if let closeButton = window.closeButton {
            closed = press(closeButton)
        } else if window.hasAction("AXClose") {
            let result = window.perform("AXClose")
            closed = result == .success
            if !closed {
                logger.warning("AXClose failed: \(result.rawValue)")
            }
        }
        guard closed, let pid = window.pid else { return }
        logger.debug("Pressed close on legacy AXWindow.")
        watch([PendingClose(window: window, pid: pid)], anchor: resolution.feedbackAnchor)
    }
}

extension HitResolution {
    /// Where feedback for this hit goes, in AppKit screen coordinates: the thumbnail, or the
    /// clicked point where the thumbnail isn't known (pre-27 Mission Control doesn't flip it).
    var feedbackAnchor: CGRect {
        thumbnailFrame ?? CGRect(origin: point, size: .zero)
    }
}
