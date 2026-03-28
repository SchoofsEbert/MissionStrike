import Cocoa
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

@MainActor
class MissionControlManager {
    static let shared = MissionControlManager()

    func handleMouseEvent(location: CGPoint, isMiddle: Bool) {
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
        // 1. Walk up the tree to find the precise accessibility window that was clicked
        if let window = findEnclosingWindow(for: element) {
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success {
                AXUIElementPerformAction(closeButtonRef as! AXUIElement, kAXPressAction as CFString)
                print("Closed window by tracing parents to AXWindow's Close Button!")
                return
            }

            var actionNames: CFArray?
            if AXUIElementCopyActionNames(window, &actionNames) == .success, let actions = actionNames as? [String] {
                if actions.contains("AXClose") {
                    AXUIElementPerformAction(window, "AXClose" as CFString)
                    print("Closed window by tracing parents to AXWindow's AXClose action!")
                    return
                }
            }
        }

        // 2. Fallback: Identify exact CGWindow under the cursor to prevent closing wrong windows in same app
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            if let cgHit = findTargetCGWindow(at: location) {
                print("Target identified via CGWindow mapping: \(cgHit.ownerName) (PID: \(cgHit.pid), WindowID: \(cgHit.windowID))")
                closeWindowByWindowID(pid: cgHit.pid, targetWindowID: cgHit.windowID)
                return
            }
            print("Could not reliably determine which window to close.")
        }
    }

    private func getParent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success {
            return (parentRef as! AXUIElement)
        }
        return nil
    }

    private func findTargetCGWindow(at location: CGPoint) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ignoredOwners = ["Dock", "Finder", "Window Server", "Wallpaper"]

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
                         if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &targetCloseBtn) == .success {
                             AXUIElementPerformAction(targetCloseBtn as! AXUIElement, kAXPressAction as CFString)
                             print("Successfully pressed close button on exact CGWindow match (\(targetWindowID)) via Accessibility on PID \(pid)")
                             return
                         }
                    }
                }
            }

            print("Could not find a close button for the target window ID (\(targetWindowID)).")
        }
    }
}
