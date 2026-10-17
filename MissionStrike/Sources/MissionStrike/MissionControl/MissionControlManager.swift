import Cocoa
import CoreGraphics
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "MissionControl")

// MARK: - Mission Control Detection Protocol

/// Abstracts Mission Control detection so implementations can be swapped in tests.
protocol MissionControlDetecting: Sendable {
    func isActive() -> Bool
}

// MARK: - Mission Control Detection

/// Checks whether Mission Control is currently active by inspecting system overlay windows.
///
/// Detection requires multiple large, opaque overlays (to reject dock-bounce false positives)
/// and at least one Dock-owned overlay among them. On macOS 27+, Mission Control's second
/// full-screen surface is owned by WindowManager rather than Dock; companion overlays from
/// config cover that case while older Dock-only sessions keep working unchanged.
///
/// Thread safety: All calls within this class use CoreGraphics APIs that are thread-safe.
/// This class is intentionally `nonisolated` / not actor-isolated so it can be called
/// synchronously from the event tap callback (which runs on the run loop thread).
final class MissionControlActiveChecker: MissionControlDetecting, Sendable {

    private let config: MissionStrikeConfig

    init(config: MissionStrikeConfig = .default) {
        self.config = config
    }

    /// Live check using system APIs (CGWindowList + NSScreen).
    func isActive() -> Bool {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screenSizes = NSScreen.screens.map { $0.frame.size }
        return Self.isActive(windowList: windowList, screenSizes: screenSizes, config: config)
    }

    /// Pure, testable detection logic with no system dependencies.
    /// Pass in window list data and screen sizes to verify heuristics.
    static func isActive(
        windowList: [[String: Any]],
        screenSizes: [CGSize],
        config: MissionStrikeConfig = .default
    ) -> Bool {
        let fraction = config.minimumScreenCoverageFraction
        let thresholds: [(minWidth: CGFloat, minHeight: CGFloat)]

        if screenSizes.isEmpty {
            let fallback = config.fallbackScreenSize
            thresholds = [(fallback.width * fraction, fallback.height * fraction)]
        } else {
            thresholds = screenSizes.map { size in
                (size.width * fraction, size.height * fraction)
            }
        }

        var dockQualifyingCount = 0
        var totalQualifyingCount = 0

        for info in windowList {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0

            let isDockOverlay = owner == "Dock"
                && config.missionControlOverlayLayers.contains(layer)
            let isCompanionOverlay = config.missionControlCompanionOverlays[owner]?.contains(layer) == true
            guard isDockOverlay || isCompanionOverlay else { continue }

            // Filter out transparent hit-test overlays (e.g. dock auto-show, app bounce)
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha >= config.minimumOverlayAlpha else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let coversAScreen = thresholds.contains { threshold in
                bounds.width > threshold.minWidth && bounds.height > threshold.minHeight
            }
            guard coversAScreen else { continue }

            totalQualifyingCount += 1
            if isDockOverlay {
                dockQualifyingCount += 1
            }

            // Require a Dock overlay so companion-only stacks cannot false-trigger,
            // while still needing enough total overlays to reject a lone dock bounce.
            if dockQualifyingCount >= 1,
               totalQualifyingCount >= config.minimumOverlayCount {
                return true
            }
        }
        return false
    }
}

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

        case .legacyAXWindow:
            // Re-hit at the same point for the AXWindow element (≤ macOS 26 Dock UI).
            guard let window = AXElement.at(resolution.point)?.ancestor(withRole: kAXWindowRole) else {
                logger.warning("Legacy AXWindow target lost before close.")
                return
            }
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
        case .legacyAXWindow:
            return AXElement.at(resolution.point)?.ancestor(withRole: kAXWindowRole)?.pid
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

// MARK: - Test helpers (window ID lookup)

extension MissionControlManager {
    /// Pure helper: look up an app window by CGWindowID (skips Dock / WindowManager / etc.).
    nonisolated static func window(
        withID windowID: CGWindowID,
        windowList: [[String: Any]],
        ignoredOwners: Set<String>
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        for info in windowList {
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            guard id == windowID else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            guard !owner.isEmpty, !ignoredOwners.contains(owner), pid != 0 else { return nil }
            return (pid, owner, windowID)
        }
        return nil
    }
}
