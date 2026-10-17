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

    /// Where the Dock and its running apps' icons are now, for `DockIconCache`.
    static func snapshot() -> DockSnapshot? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL })

        var snapshot = DockSnapshot(listFrames: [], runningAppIcons: [], magnification: magnificationReach())
        for list in children(of: dockElement) where string(list, kAXRoleAttribute) == kAXListRole {
            guard let listFrame = frame(of: list) else { continue }
            snapshot.listFrames.append(listFrame)
            for item in children(of: list) where string(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
                guard let url = url(of: item), running.contains(url), let iconFrame = frame(of: item) else {
                    continue
                }
                snapshot.runningAppIcons.append(iconFrame)
            }
        }
        return snapshot
    }

    /// How much bigger than at rest a magnified icon gets; 0 with magnification off.
    private static func magnificationReach() -> CGFloat {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        guard dockDefaults?.bool(forKey: "magnification") == true else { return 0 }
        let tileSize = dockDefaults?.double(forKey: "tilesize") ?? 0
        let largeSize = dockDefaults?.double(forKey: "largesize") ?? 0
        // The Dock's own maximum when the sizes aren't stored.
        return largeSize > tileSize ? CGFloat(largeSize - tileSize) : 128
    }

    /// The running app behind a Dock icon, or nil when the app isn't running.
    private static func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        guard let url = url(of: item) else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url
        }
    }

    private static func url(of item: AXUIElement) -> URL? {
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success else {
            return nil
        }
        return (urlRef as? URL)?.standardizedFileURL
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
