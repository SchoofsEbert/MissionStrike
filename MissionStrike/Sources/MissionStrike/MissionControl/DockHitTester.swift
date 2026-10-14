import AppKit
import ApplicationServices

/// Finds the running app whose Dock icon is under the pointer, through the Dock's
/// Accessibility tree (`AXList` of `AXDockItem`s).
enum DockHitTester {
    struct Hit: @unchecked Sendable {
        let app: NSRunningApplication
        /// Icon frame in AX (top-left origin) space.
        let iconFrame: CGRect
    }

    /// - Parameter candidates: Points in AX space; the first one inside an icon wins.
    static func runningApp(at candidates: [CGPoint]) -> Hit? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)

        for list in children(of: dockElement) where string(list, kAXRoleAttribute) == kAXListRole {
            // Cheap reject: only walk the icons when the pointer is on the Dock at all.
            guard let listFrame = frame(of: list), candidates.contains(where: listFrame.contains) else {
                continue
            }
            for item in children(of: list) where string(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
                guard let iconFrame = frame(of: item), candidates.contains(where: iconFrame.contains) else {
                    continue
                }
                guard let app = runningApp(for: item) else { return nil }
                return Hit(app: app, iconFrame: iconFrame)
            }
        }
        return nil
    }

    /// The running app behind a Dock icon, or nil when the app isn't running.
    private static func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success,
              let url = (urlRef as? URL)?.standardizedFileURL else {
            return nil
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url
        }
    }

    // MARK: - AX helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: size)
    }
}
