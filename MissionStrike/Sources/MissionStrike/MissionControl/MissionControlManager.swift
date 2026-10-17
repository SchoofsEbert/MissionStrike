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

    /// Performs a pre-resolved hit from the event tap.
    func perform(resolution: MissionControlHitTester.Resolution, action: MouseAction) {
        if action != .minimize, !isDesktop(resolution) {
            CloseEffect.play(for: resolution)
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
                closeAllWindows(forPID: pid)
            case .minimize:
                minimizeWindow(pid: pid, windowID: windowID)
            }

        case .legacyAXWindow(let window):
            switch action {
            case .close:
                closeLegacyAXWindow(window, resolution: resolution)
            case .closeAll:
                if let pid = window.pid {
                    closeAllWindows(forPID: pid)
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
            CloseEffect.play(at: NSEvent.mouseLocation)
            logger.debug("Closed Space via AXRemoveDesktop.")
        } else {
            logger.warning("AXRemoveDesktop failed with error: \(result.rawValue)")
        }
    }

    private func isDesktop(_ resolution: MissionControlHitTester.Resolution) -> Bool {
        if case .removeDesktop = resolution.target { return true }
        return false
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
        logger.debug("Closed CGWindow \(targetWindowID) on PID \(pid).")
        flashIfConfirmationNeeded(resolution) { [weak self] in
            self?.axWindow(pid: pid, windowID: targetWindowID)
        }
    }

    private func minimizeWindow(pid: Int32, windowID: CGWindowID) {
        guard let window = axWindow(pid: pid, windowID: windowID) else {
            logger.warning("Could not find window \(windowID) to minimize.")
            return
        }
        minimize(window)
    }

    /// Closes every window of the app, optionally keeping one ("Close Other Windows").
    func closeAllWindows(forPID pid: pid_t, except keptWindowID: CGWindowID? = nil) {
        guard let windows = AXElement.application(pid).windows else {
            logger.warning("Could not enumerate windows for close-all on PID \(pid).")
            return
        }
        var closedCount = 0
        for window in windows {
            if let keptWindowID, window.windowID == keptWindowID {
                continue
            }
            if pressCloseButton(of: window) {
                closedCount += 1
            }
        }
        logger.debug("Closed \(closedCount)/\(windows.count) windows for PID \(pid).")
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

    // MARK: - Confirmation dialogs

    /// How long an app gets to either close the window or put up a sheet.
    private static let confirmationCheckDelay: Duration = .milliseconds(400)

    /// A close that asks for confirmation (unsaved changes, running processes) opens a sheet
    /// the user can't see behind Mission Control. Show a badge on the thumbnail until the sheet
    /// goes or Mission Control closes, so the window doesn't look like it ignored the click.
    private func flashIfConfirmationNeeded(
        _ resolution: MissionControlHitTester.Resolution,
        findWindow: @escaping @MainActor () -> AXElement?
    ) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.confirmationCheckDelay)
            guard let window = findWindow(), Self.hasSheet(window) else { return }
            logger.debug("Close is waiting on a confirmation sheet.")
            let thumbnail = resolution.thumbnailFrame ?? CGRect(origin: resolution.point, size: .zero)
            HoverBadgeController.shared.flash(.needsConfirmation, on: thumbnail) {
                findWindow().map(Self.hasSheet) ?? false
            }
        }
    }

    private static func hasSheet(_ window: AXElement) -> Bool {
        window.children.contains { $0.role == kAXSheetRole }
    }

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
        guard closed else { return }
        logger.debug("Closed legacy AXWindow.")
        flashIfConfirmationNeeded(resolution) { window }
    }
}
