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
        // Spaces Bar (macOS 27+: may hit AXList/AXGroup; resolve the desktop button).
        if let spaceButton = findSpaceCloseButton(from: element, at: location) {
            let enableSpaceClosing = UserDefaults.standard.bool(forKey: "enableSpaceClosing")
            if enableSpaceClosing {
                let closeResult = AXUIElementPerformAction(spaceButton, "AXRemoveDesktop" as CFString)
                if closeResult == .success {
                    logger.debug("Closed Space via AXRemoveDesktop.")
                } else {
                    logger.warning("AXRemoveDesktop failed with error: \(closeResult.rawValue)")
                }
            }
            return
        }

        // Legacy path: Dock-hosted Mission Control exposed real AXWindow ancestors (≤ macOS 26).
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

        // macOS 27+: WindowManager thumbnails expose `wid` = real CGWindowID.
        // Do not guess via frame/point overlap — that closes unrelated windows.
        if let cgHit = resolveTargetCGWindow(from: element) {
            logger.debug("Target via thumbnail wid: \(cgHit.ownerName) (PID: \(cgHit.pid), WindowID: \(cgHit.windowID))")
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

    /// Resolves the real app window from a Mission Control thumbnail.
    ///
    /// Only uses the undocumented `wid` attribute. Geometric heuristics were removed
    /// because they frequently closed the wrong window on macOS 27.
    private func resolveTargetCGWindow(
        from element: AXUIElement
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        guard let windowID = missionControlWindowID(from: element) else { return nil }

        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return Self.window(
            withID: windowID,
            windowList: windowListInfo,
            ignoredOwners: MissionStrikeConfig.default.ignoredWindowOwners
        )
    }

    /// Reads the undocumented Mission Control thumbnail `wid` attribute (CGWindowID).
    private func missionControlWindowID(from element: AXUIElement) -> CGWindowID? {
        var current: AXUIElement? = element
        while let elem = current {
            if let wid = axUInt32Attribute(elem, "wid"), wid != 0 {
                return wid
            }
            current = getParent(of: elem)
        }
        return nil
    }

    private func axUInt32Attribute(_ element: AXUIElement, _ name: String) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        var number: Int64 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &number), number > 0 else { // swiftlint:disable:this force_cast
            return nil
        }
        return CGWindowID(number)
    }

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
        guard frame.width > 1, frame.height > 1 else { return nil }
        return frame
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
        if findSpaceCloseButton(from: element, at: location) != nil { return }

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

        if let cgHit = resolveTargetCGWindow(from: element) {
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
        if findSpaceCloseButton(from: element, at: location) != nil {
            attemptToClose(element: element, at: location)
            return
        }

        // Must resolve via thumbnail wid — AX pid is WindowManager on macOS 27+.
        guard let cgHit = resolveTargetCGWindow(from: element) else {
            logger.warning("Could not determine app PID for close-all.")
            return
        }
        let pid = cgHit.pid

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

    // MARK: - Spaces Bar

    /// Finds the desktop thumbnail that can be removed, even when the hit-test
    /// lands on the surrounding AXList / AXGroup instead of the button itself.
    private func findSpaceCloseButton(from element: AXUIElement, at location: CGPoint) -> AXUIElement? {
        if hasAction(element, "AXRemoveDesktop") {
            return element
        }

        guard let spacesBar = findAncestor(titled: "Spaces Bar", from: element) else {
            return nil
        }

        // Prefer a desktop button whose frame contains the click.
        if let match = findDescendant(in: spacesBar, matching: { candidate in
            hasAction(candidate, "AXRemoveDesktop")
                && (axFrame(of: candidate)?.contains(location) ?? false)
        }) {
            return match
        }

        // Hit the Spaces Bar chrome but not a specific desktop — do nothing
        // rather than removing an arbitrary Space.
        return nil
    }

    private func findAncestor(titled title: String, from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let elem = current {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &titleRef)
            if let titleStr = titleRef as? String, titleStr == title {
                return elem
            }
            current = getParent(of: elem)
        }
        return nil
    }

    private func findDescendant(
        in root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if predicate(root) { return root }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findDescendant(in: child, matching: predicate) {
                return found
            }
        }
        return nil
    }

    private func hasAction(_ element: AXUIElement, _ action: String) -> Bool {
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let actions = actionNames as? [String] else {
            return false
        }
        return actions.contains(action)
    }
}
