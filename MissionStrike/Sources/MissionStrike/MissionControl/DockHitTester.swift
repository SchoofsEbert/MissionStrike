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
        guard let dock = dockElement() else { return nil }

        for list in dock.children where list.role == kAXListRole {
            // Cheap reject: only walk the icons when the pointer is on the Dock at all.
            guard let listFrame = list.frame, candidates.contains(where: listFrame.contains) else {
                continue
            }
            for item in list.children where item.subrole == "AXApplicationDockItem" {
                guard let iconFrame = item.frame, candidates.contains(where: iconFrame.contains) else {
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
        guard let dock = dockElement() else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL })

        var snapshot = DockSnapshot(listFrames: [], runningAppIcons: [], magnification: magnificationReach())
        for list in dock.children where list.role == kAXListRole {
            guard let listFrame = list.frame else { continue }
            snapshot.listFrames.append(listFrame)
            for item in list.children where item.subrole == "AXApplicationDockItem" {
                guard let url = item.url, running.contains(url), let iconFrame = item.frame else {
                    continue
                }
                snapshot.runningAppIcons.append(iconFrame)
            }
        }
        return snapshot
    }

    private static func dockElement() -> AXElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            .map { AXElement.application($0.processIdentifier) }
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
    private static func runningApp(for item: AXElement) -> NSRunningApplication? {
        guard let url = item.url else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == url
        }
    }
}
