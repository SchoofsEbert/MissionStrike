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

    func handleMouseEvent(location: CGPoint, action: MouseAction = .close) {
        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtPosition: AXUIElement?

        let result = AXUIElementCopyElementAtPosition(
            systemWideElement, Float(location.x), Float(location.y), &elementAtPosition
        )

        guard result == .success, let element = elementAtPosition else { return }

        switch action {
        case .close:
            attemptToClose(element: element, at: location)
        case .closeAll:
            closeAllWindowsForApp(element: element, at: location)
        case .minimize:
            minimizeWindow(element: element, at: location)
        }
    }

    private func findEnclosingWindow(for element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let elem = current {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &role)
            if let roleStr = role as? String, roleStr == "AXWindow" {
                return elem
            }
            current = getParent(of: elem)
        }
        return nil
    }

    private func attemptToClose(element: AXUIElement, at location: CGPoint) {
        if isInSpacesBar(element: element) {
            let enableSpaceClosing = UserDefaults.standard.bool(forKey: "enableSpaceClosing")
            if enableSpaceClosing {
                var actionNames: CFArray?
                if AXUIElementCopyActionNames(element, &actionNames) == .success, let actions = actionNames as? [String] {
                    if actions.contains("AXRemoveDesktop") {
                        let closeResult = AXUIElementPerformAction(element, "AXRemoveDesktop" as CFString)
                        if closeResult == .success {
                            logger.debug("Closed Space via AXRemoveDesktop.")
                        } else {
                            logger.warning("AXRemoveDesktop failed with error: \(closeResult.rawValue)")
                        }
                    }
                }
            }
            return
        }

        // 1. Walk up the tree to find the precise accessibility window that was clicked
        //    (legacy Dock-hosted Mission Control UI on older macOS).
        if let window = findEnclosingWindow(for: element) {
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
               let closeButtonRef {
                let closeButton = closeButtonRef as! AXUIElement // swiftlint:disable:this force_cast
                let closeResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                if closeResult == .success {
                    logger.debug("Closed window via AXWindow's Close Button.")
                } else {
                    logger.warning("AXPress on close button failed with error: \(closeResult.rawValue)")
                }
                return
            }

            var actionNames: CFArray?
            if AXUIElementCopyActionNames(window, &actionNames) == .success, let actions = actionNames as? [String] {
                if actions.contains("AXClose") {
                    let closeResult = AXUIElementPerformAction(window, "AXClose" as CFString)
                    if closeResult == .success {
                        logger.debug("Closed window via AXWindow's AXClose action.")
                    } else {
                        logger.warning("AXClose action failed with error: \(closeResult.rawValue)")
                    }
                    return
                }
            }
        }

        // 2. Fallback: map Mission Control thumbnails (WindowManager AXButtons on macOS 27+)
        //    or cursor position onto the real app CGWindow, then close via Accessibility.
        if let cgHit = resolveTargetCGWindow(from: element, at: location) {
            logger.debug("Target identified via CGWindow mapping: \(cgHit.ownerName) (PID: \(cgHit.pid), WindowID: \(cgHit.windowID))")
            closeWindowByWindowID(pid: cgHit.pid, targetWindowID: cgHit.windowID)
            return
        }
        logger.warning("Could not reliably determine which window to close.")
    }

    private func getParent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let parentRef {
            return (parentRef as! AXUIElement) // swiftlint:disable:this force_cast
        }
        return nil
    }

    /// Resolves the real app window under a Mission Control click.
    ///
    /// On macOS 27+, thumbnails are WindowManager `AXButton`s with no `AXWindow`
    /// ancestor, so we match the button's AX frame (or click point) against layer-0
    /// CGWindows belonging to real apps.
    private func resolveTargetCGWindow(
        from element: AXUIElement,
        at location: CGPoint
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ignoredOwners = MissionStrikeConfig.default.ignoredWindowOwners

        // Prefer the AX frame of the clicked thumbnail / control.
        if let axFrame = axFrame(of: element) ?? nearestAncestorFrame(of: element),
           let match = Self.bestOverlappingWindow(
            axFrame: axFrame,
            windowList: windowListInfo,
            ignoredOwners: ignoredOwners
           ) {
            return match
        }

        // Point-in-bounds fallback (Cocoa / upper-left coordinates).
        return Self.windowContainingPoint(
            location,
            windowList: windowListInfo,
            ignoredOwners: ignoredOwners
        )
    }

    /// Pure helper: pick the layer-0 app window with the largest intersection area.
    nonisolated static func bestOverlappingWindow(
        axFrame: CGRect,
        windowList: [[String: Any]],
        ignoredOwners: Set<String>
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        var best: (pid: Int32, ownerName: String, windowID: CGWindowID, area: CGFloat)?

        for info in windowList {
            guard let candidate = layerZeroAppWindow(from: info, ignoredOwners: ignoredOwners),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let intersection = axFrame.intersection(bounds)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            // Require a meaningful overlap so tiny edge hits don't steal the target.
            let minArea = min(axFrame.width * axFrame.height, bounds.width * bounds.height) * 0.15
            guard area >= minArea else { continue }

            if best == nil || area > best!.area {
                best = (candidate.pid, candidate.ownerName, candidate.windowID, area)
            }
        }

        if let best {
            return (best.pid, best.ownerName, best.windowID)
        }
        return nil
    }

    /// Pure helper: first layer-0 app window whose bounds contain the point.
    nonisolated static func windowContainingPoint(
        _ location: CGPoint,
        windowList: [[String: Any]],
        ignoredOwners: Set<String>
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        for info in windowList {
            guard let candidate = layerZeroAppWindow(from: info, ignoredOwners: ignoredOwners),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(location) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private nonisolated static func layerZeroAppWindow(
        from info: [String: Any],
        ignoredOwners: Set<String>
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
        let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
        guard layer == 0, !owner.isEmpty, !ignoredOwners.contains(owner), pid != 0, windowID != 0 else {
            return nil
        }
        return (pid, owner, windowID)
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin), // swiftlint:disable:this force_cast
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { // swiftlint:disable:this force_cast
            return nil
        }
        let frame = CGRect(origin: origin, size: size)
        // Skip empty / degenerate frames (e.g. AXApplication).
        guard frame.width > 1, frame.height > 1 else { return nil }
        return frame
    }

    private func nearestAncestorFrame(of element: AXUIElement) -> CGRect? {
        var current: AXUIElement? = getParent(of: element)
        while let elem = current {
            if let frame = axFrame(of: elem), frame.width < 10_000, frame.height < 10_000 {
                // Prefer reasonably sized frames (skip the full-screen MC root group).
                let screens = NSScreen.screens.map(\.frame.size)
                let isFullScreenOverlay = screens.contains {
                    frame.width >= $0.width * 0.9 && frame.height >= $0.height * 0.9
                }
                if !isFullScreenOverlay {
                    return frame
                }
            }
            current = getParent(of: elem)
        }
        return nil
    }

    private func closeWindowByWindowID(pid: Int32, targetWindowID: CGWindowID) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?

        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {

            for window in windows {
                var cgWindowID: CGWindowID = 0
                if _AXUIElementGetWindow(window, &cgWindowID) == .success {
                    if cgWindowID == targetWindowID {
                        var targetCloseBtn: CFTypeRef?
                        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &targetCloseBtn) == .success,
                           let targetCloseBtn {
                            let closeButton = targetCloseBtn as! AXUIElement // swiftlint:disable:this force_cast
                            let closeResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                            if closeResult == .success {
                                logger.debug("Closed exact CGWindow match (\(targetWindowID)) via Accessibility on PID \(pid).")
                            } else {
                            logger.warning(
                                "AXPress on close button for window \(targetWindowID) failed with error: \(closeResult.rawValue)"
                            )
                            }
                            return
                        }
                    }
                }
            }

            logger.warning("Could not find a close button for the target window ID (\(targetWindowID)).")
        }
    }

    // MARK: - Minimize (#15)

    private func minimizeWindow(element: AXUIElement, at location: CGPoint) {
        // Don't minimize Spaces — that doesn't make sense
        if isInSpacesBar(element: element) { return }

        if let window = findEnclosingWindow(for: element) {
            let minimizeResult = AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, true as CFTypeRef
            )
            if minimizeResult == .success {
                logger.debug("Minimized window via AXMinimized attribute.")
            } else {
                logger.warning("AXMinimized failed with error: \(minimizeResult.rawValue)")
            }
            return
        }

        // Fallback: CGWindow identification (required on macOS 27+ WindowManager thumbnails)
        if let cgHit = resolveTargetCGWindow(from: element, at: location) {
            let appElement = AXUIElementCreateApplication(cgHit.pid)
            var windowsRef: CFTypeRef?

            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for window in windows {
                    var cgWindowID: CGWindowID = 0
                    if _AXUIElementGetWindow(window, &cgWindowID) == .success,
                       cgWindowID == cgHit.windowID {
                        let minimizeResult = AXUIElementSetAttributeValue(
                            window, kAXMinimizedAttribute as CFString, true as CFTypeRef
                        )
                        if minimizeResult == .success {
                            logger.debug("Minimized CGWindow \(cgHit.windowID) on PID \(cgHit.pid).")
                        } else {
                            logger.warning("AXMinimized for window \(cgHit.windowID) failed: \(minimizeResult.rawValue)")
                        }
                        return
                    }
                }
            }
        }
        logger.warning("Could not find a window to minimize.")
    }

    // MARK: - Close All App Windows (#14)

    private func closeAllWindowsForApp(element: AXUIElement, at location: CGPoint) {
        // Don't close-all from Spaces bar — use normal close for Spaces
        if isInSpacesBar(element: element) {
            attemptToClose(element: element, at: location)
            return
        }

        // Resolve the real app PID via CGWindow mapping. On macOS 27+ the clicked
        // element belongs to WindowManager, so AXUIElementGetPid is the wrong process.
        let pid: pid_t
        if let cgHit = resolveTargetCGWindow(from: element, at: location) {
            pid = cgHit.pid
        } else {
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success else {
                logger.warning("Could not determine app PID for close-all.")
                return
            }
            pid = elementPID
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            logger.warning("Could not enumerate windows for PID \(pid).")
            return
        }

        var closedCount = 0
        for window in windows {
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
               let closeButtonRef {
                let closeButton = closeButtonRef as! AXUIElement // swiftlint:disable:this force_cast
                if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
                    closedCount += 1
                }
            }
        }
        logger.debug("Closed \(closedCount)/\(windows.count) windows for PID \(pid).")
    }

    // MARK: - Helpers

    private func isInSpacesBar(element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        while let elem = current {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)
            if let titleStr = title as? String, titleStr == "Spaces Bar" {
                return true
            }
            current = getParent(of: elem)
        }
        return false
    }
}
