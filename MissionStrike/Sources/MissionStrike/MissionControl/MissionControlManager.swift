import Cocoa
import CoreGraphics
import ApplicationServices
import os.log

// MARK: - Private API Declaration
// WARNING: _AXUIElementGetWindow is an undocumented Apple-private API.
// It maps an AXUIElement window to its CGWindowID. This is used as a fallback
// when the Accessibility tree alone cannot identify the correct window.
// Risk: may break in future macOS versions; guarantees App Store rejection.
// The fallback path degrades gracefully if this function fails.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "MissionControl")

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
        switch resolution.target {
        case .removeDesktop(let button):
            guard action == .close || action == .closeAll else { return }
            guard UserDefaults.standard.bool(forKey: "enableSpaceClosing") else {
                logger.info("Space close skipped — enableSpaceClosing is off.")
                return
            }
            let result = AXUIElementPerformAction(button, "AXRemoveDesktop" as CFString)
            if result == .success {
                logger.debug("Closed Space via AXRemoveDesktop.")
            } else {
                logger.warning("AXRemoveDesktop failed with error: \(result.rawValue)")
            }

        case .window(let pid, let ownerName, let windowID):
            switch action {
            case .close:
                logger.debug("Closing wid \(windowID) (\(ownerName), pid \(pid)).")
                closeWindowByWindowID(pid: pid, targetWindowID: windowID)
            case .closeAll:
                closeAllWindows(forPID: pid)
            case .minimize:
                minimizeWindow(pid: pid, windowID: windowID)
            }

        case .legacyAXWindow:
            // Re-hit at the same point for the AXWindow element (≤ macOS 26 Dock UI).
            guard let element = element(at: resolution.point),
                  let window = enclosingWindow(from: element) else {
                logger.warning("Legacy AXWindow target lost before close.")
                return
            }
            switch action {
            case .close:
                closeLegacyAXWindow(window)
            case .closeAll:
                var pid: pid_t = 0
                AXUIElementGetPid(window, &pid)
                closeAllWindows(forPID: pid)
            case .minimize:
                minimizeLegacyAXWindow(window)
            }
        }
    }

    // MARK: - Window actions

    private func closeWindowByWindowID(pid: Int32, targetWindowID: CGWindowID) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            logger.warning("Could not enumerate windows for PID \(pid).")
            return
        }

        for window in windows {
            var cgWindowID: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &cgWindowID) == .success,
                  cgWindowID == targetWindowID else { continue }

            var closeButtonRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXCloseButtonAttribute as CFString, &closeButtonRef
            ) == .success,
                  let closeButtonRef else {
                logger.warning("No close button for window \(targetWindowID).")
                return
            }
            let closeButton = closeButtonRef as! AXUIElement // swiftlint:disable:this force_cast
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if result == .success {
                logger.debug("Closed CGWindow \(targetWindowID) on PID \(pid).")
            } else {
                logger.warning("AXPress on close button failed: \(result.rawValue)")
            }
            return
        }
        logger.warning("Could not find AX window for CGWindowID \(targetWindowID).")
    }

    private func minimizeWindow(pid: Int32, windowID: CGWindowID) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            logger.warning("Could not enumerate windows to minimize for PID \(pid).")
            return
        }
        for window in windows {
            var cgWindowID: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &cgWindowID) == .success,
                  cgWindowID == windowID else { continue }
            let result = AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, true as CFTypeRef
            )
            if result == .success {
                logger.debug("Minimized CGWindow \(windowID) on PID \(pid).")
            } else {
                logger.warning("AXMinimized failed: \(result.rawValue)")
            }
            return
        }
        logger.warning("Could not find window \(windowID) to minimize.")
    }

    private func closeAllWindows(forPID pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            logger.warning("Could not enumerate windows for close-all on PID \(pid).")
            return
        }
        var closedCount = 0
        for window in windows {
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window, kAXCloseButtonAttribute as CFString, &closeButtonRef
            ) == .success,
               let closeButtonRef {
                let closeButton = closeButtonRef as! AXUIElement // swiftlint:disable:this force_cast
                if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
                    closedCount += 1
                }
            }
        }
        logger.debug("Closed \(closedCount)/\(windows.count) windows for PID \(pid).")
    }

    private func closeLegacyAXWindow(_ window: AXUIElement) {
        var closeButtonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
           let closeButtonRef {
            let closeButton = closeButtonRef as! AXUIElement // swiftlint:disable:this force_cast
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if result == .success {
                logger.debug("Closed window via AXWindow close button.")
            } else {
                logger.warning("AXPress on close button failed: \(result.rawValue)")
            }
            return
        }
        var actionNames: CFArray?
        if AXUIElementCopyActionNames(window, &actionNames) == .success,
           let actions = actionNames as? [String],
           actions.contains("AXClose") {
            let result = AXUIElementPerformAction(window, "AXClose" as CFString)
            if result == .success {
                logger.debug("Closed window via AXClose.")
            } else {
                logger.warning("AXClose failed: \(result.rawValue)")
            }
        }
    }

    private func minimizeLegacyAXWindow(_ window: AXUIElement) {
        let result = AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, true as CFTypeRef
        )
        if result == .success {
            logger.debug("Minimized legacy AXWindow.")
        } else {
            logger.warning("AXMinimized failed: \(result.rawValue)")
        }
    }

    // MARK: - Re-hit helpers (Spaces / legacy)

    private func element(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &element
        )
        guard result == .success else { return nil }
        return element
    }

    private func enclosingWindow(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let elem = current {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &role)
            if let roleStr = role as? String, roleStr == "AXWindow" {
                return elem
            }
            current = parent(of: elem)
        }
        return nil
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parentRef else {
            return nil
        }
        return (parentRef as! AXUIElement) // swiftlint:disable:this force_cast
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
