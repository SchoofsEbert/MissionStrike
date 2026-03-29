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

// MARK: - Mission Control Detection

/// Checks whether Mission Control is currently active by inspecting Dock-owned overlay windows.
///
/// Thread safety: All calls within this class use CoreGraphics APIs that are thread-safe.
/// This class is intentionally `nonisolated` / not actor-isolated so it can be called
/// synchronously from the event tap callback (which runs on the run loop thread).
final class MissionControlActiveChecker: Sendable {

    // Dock overlay window layers observed during Mission Control (macOS 13–15).
    private static let missionControlOverlayLayers: Set<Int> = [18, 20]

    // Minimum fraction of the main screen that a Dock overlay must cover
    // to be considered a Mission Control overlay (avoids false positives on small Dock windows).
    private static let minimumScreenCoverageFraction: CGFloat = 0.5

    static func isActive() -> Bool {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let mainScreenSize = NSScreen.main?.frame.size ?? NSSize(width: 1920, height: 1080)
        let minWidth = mainScreenSize.width * minimumScreenCoverageFraction
        let minHeight = mainScreenSize.height * minimumScreenCoverageFraction

        for info in windowListInfo {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0

            // Mission Control creates full-screen overlay windows at specific layers, owned by the Dock.
            if owner == "Dock" && missionControlOverlayLayers.contains(layer) {
                if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                   let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                    if bounds.width > minWidth && bounds.height > minHeight {
                        return true
                    }
                }
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

    func handleMouseEvent(location: CGPoint) {
        closeWindowAt(location: location)
    }

    private func closeWindowAt(location: CGPoint) {
        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtPosition: AXUIElement?

        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(location.x), Float(location.y), &elementAtPosition)

        if result == .success, let element = elementAtPosition {
            attemptToClose(element: element, at: location)
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
        var current: AXUIElement? = element
        var inSpacesBar = false
        while let elem = current {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)

            if let titleStr = title as? String, titleStr == "Spaces Bar" {
                inSpacesBar = true
                break
            }
            current = getParent(of: elem)
        }

        if inSpacesBar {
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

        // 2. Fallback: Identify exact CGWindow under the cursor to prevent closing wrong windows in same app
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            if let cgHit = findTargetCGWindow(at: location) {
                logger.debug("Target identified via CGWindow mapping: \(cgHit.ownerName) (PID: \(cgHit.pid), WindowID: \(cgHit.windowID))")
                closeWindowByWindowID(pid: cgHit.pid, targetWindowID: cgHit.windowID)
                return
            }
            logger.warning("Could not reliably determine which window to close.")
        }
    }

    private func getParent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let parentRef {
            return (parentRef as! AXUIElement) // swiftlint:disable:this force_cast
        }
        return nil
    }

    private func findTargetCGWindow(at location: CGPoint) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ignoredOwners: Set<String> = ["Dock", "Window Server", "Wallpaper"]

        for info in windowListInfo {
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
               let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                if bounds.contains(location) {
                    let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
                    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                    let layer = info[kCGWindowLayer as String] as? Int ?? 0
                    let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0

                    if layer == 0 && !ignoredOwners.contains(owner) && !owner.isEmpty {
                        return (pid, owner, windowID)
                    }
                }
            }
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
}
