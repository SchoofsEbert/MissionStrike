import AppKit
import ApplicationServices
import CoreGraphics

/// Synchronous hit testing for the event tap (must stay fast — runs on the tap callback).
///
/// **macOS 27+:** Mission Control thumbnails are WindowManager `AXButton`s with an
/// undocumented `wid` (CGWindowID). Click Y is mirrored vs AX frames, so we Y-flip once.
///
/// **macOS ≤26:** Dock-era UI exposes real `AXWindow`s; no Y-flip, legacy close path.
enum MissionControlHitTester {

    enum Target: @unchecked Sendable {
        case removeDesktop(AXUIElement)
        case window(pid: Int32, ownerName: String, windowID: CGWindowID)
        case legacyAXWindow
    }

    struct Resolution: @unchecked Sendable {
        let target: Target
        /// Point in AX hit-test space (after any OS-gated Y-flip).
        let point: CGPoint
    }

    /// Reject AX padding around thumbnail buttons (greedy hit targets on 27).
    private static let thumbnailEdgeInsetFraction: CGFloat = 0.10

    /// Below this Y (AX space), treat the click as Spaces-strip only — never a window.
    private static let spacesStripMaxY: CGFloat = 140

    // MARK: - Public API

    /// - Parameter clickPoint: Cursor position (`NSEvent.mouseLocation` space).
    static func resolve(clickPoint: CGPoint) -> Resolution? {
        let useFlip = shouldYFlipForMissionControl()
        let point = useFlip ? ScreenCoordinates.yFlipped(clickPoint) : clickPoint

        if let button = spaceButton(at: point) {
            return Resolution(target: .removeDesktop(button), point: point)
        }

        // Missed a desktop but still in the Spaces strip → do not close a window.
        if point.y < spacesStripMaxY, isInSpacesStrip(point) {
            return nil
        }

        if let window = resolveThumbnailWindow(at: point) {
            return Resolution(
                target: .window(pid: window.pid, ownerName: window.ownerName, windowID: window.windowID),
                point: point
            )
        }

        // Pre-wid Mission Control (≤26): enclosing AXWindow, unflipped path only.
        if !useFlip, resolveLegacyAXWindow(at: point) != nil {
            return Resolution(target: .legacyAXWindow, point: point)
        }
        return nil
    }

    /// Desktop button for `AXRemoveDesktop` at an AX-space point.
    private static func spaceButton(at point: CGPoint) -> AXUIElement? {
        guard point.y < spacesStripMaxY + 40 else { return nil }

        // Prefer live hit-test once the Spaces Bar is revealed.
        if let hit = element(at: point) {
            var cur: AXUIElement? = hit
            for _ in 0..<8 {
                guard let elem = cur else { break }
                if hasAction(elem, "AXRemoveDesktop") {
                    return elem
                }
                if title(of: elem) == "Spaces Bar" {
                    return nearestDesktop(in: removableDesktopButtons(in: elem), to: point)
                }
                cur = parent(of: elem)
            }
        }

        return nearestDesktop(in: allRemovableDesktopButtons(), to: point)
    }

    // MARK: - Y-flip gate

    /// macOS 27+ Mission Control reports click Y mirrored vs AX frames.
    private static func shouldYFlipForMissionControl() -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    // MARK: - Windows (wid)

    private static func resolveThumbnailWindow(
        at point: CGPoint
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        guard let hit = element(at: point),
              let button = ancestorWithWid(from: hit),
              let windowID = readWid(button),
              let buttonFrame = frame(of: button) else {
            return nil
        }

        let inset = buttonFrame.insetBy(
            dx: buttonFrame.width * thumbnailEdgeInsetFraction,
            dy: buttonFrame.height * thumbnailEdgeInsetFraction
        )
        guard inset.width > 8, inset.height > 8, inset.contains(point) else {
            return nil
        }
        return lookupWindow(id: windowID)
    }

    private static func lookupWindow(
        id windowID: CGWindowID
    ) -> (pid: Int32, ownerName: String, windowID: CGWindowID)? {
        let ignored = MissionStrikeConfig.default.ignoredWindowOwners
        for options: CGWindowListOption in [.optionOnScreenOnly, .optionAll] {
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
                  let found = MissionControlManager.window(
                    withID: windowID,
                    windowList: list,
                    ignoredOwners: ignored
                  ) else {
                continue
            }
            return found
        }
        return nil
    }

    private static func ancestorWithWid(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let elem = current, depth < 8 {
            if let wid = readWid(elem), wid != 0 {
                return elem
            }
            current = parent(of: elem)
            depth += 1
        }
        return nil
    }

    // MARK: - Spaces

    private static func isInSpacesStrip(_ point: CGPoint) -> Bool {
        if let bar = findSpacesBar(), let f = frame(of: bar),
           f.insetBy(dx: 0, dy: -32).contains(point) {
            return true
        }
        if let hit = element(at: point) {
            var cur: AXUIElement? = hit
            for _ in 0..<8 {
                guard let elem = cur else { break }
                if title(of: elem) == "Spaces Bar" || hasAction(elem, "AXRemoveDesktop") {
                    return true
                }
                cur = parent(of: elem)
            }
        }
        return false
    }

    /// Nearest desktop whose inflated frame contains the point, else nil.
    private static func nearestDesktop(in desktops: [AXUIElement], to point: CGPoint) -> AXUIElement? {
        guard !desktops.isEmpty else { return nil }

        var containing: [(AXUIElement, CGFloat)] = []
        for button in desktops {
            guard let f = frame(of: button) else { continue }
            // AX frames are smaller than the visible Space preview.
            let hitFrame = f.insetBy(dx: -16, dy: -28)
            guard hitFrame.contains(point) else { continue }
            containing.append((button, hypot(f.midX - point.x, f.midY - point.y)))
        }
        return containing.min(by: { $0.1 < $1.1 })?.0
    }

    private static func findSpacesBar() -> AXUIElement? {
        guard let root = windowManagerApplication() else { return nil }
        return descendant(in: root) { title(of: $0) == "Spaces Bar" }
    }

    private static func allRemovableDesktopButtons() -> [AXUIElement] {
        if let root = windowManagerApplication() {
            let buttons = removableDesktopButtons(in: root)
            if !buttons.isEmpty { return buttons }
        }
        return []
    }

    private static func windowManagerApplication() -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: {
            $0.localizedName == "WindowManager" || $0.bundleIdentifier == "com.apple.WindowManager"
        }) else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func removableDesktopButtons(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func walk(_ element: AXUIElement) {
            if hasAction(element, "AXRemoveDesktop") {
                result.append(element)
            }
            for child in children(of: element) {
                walk(child)
            }
        }
        walk(root)
        return result
    }

    private static func descendant(
        in root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if predicate(root) { return root }
        for child in children(of: root) {
            if let found = descendant(in: child, matching: predicate) {
                return found
            }
        }
        return nil
    }

    // MARK: - Legacy ≤26

    private static func resolveLegacyAXWindow(at point: CGPoint) -> AXUIElement? {
        guard let element = element(at: point),
              readWid(element) == nil,
              ancestorWithWid(from: element) == nil,
              !isSystemOverlayApp(element) else {
            return nil
        }
        return enclosingWindow(from: element)
    }

    // MARK: - AX helpers

    private static func element(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &element
        )
        guard result == .success else { return nil }
        return element
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parentRef else {
            return nil
        }
        return (parentRef as! AXUIElement)
    }

    private static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private static func title(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private static func readWid(_ element: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "wid" as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        var number: Int64 = 0
        guard CFNumberGetValue((value as! CFNumber), .sInt64Type, &number), number > 0 else {
            return nil
        }
        return CGWindowID(number)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }
        let rect = CGRect(origin: origin, size: size)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success else {
            return []
        }
        return (childrenRef as? [AXUIElement]) ?? []
    }

    private static func hasAction(_ element: AXUIElement, _ action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else {
            return false
        }
        return actions.contains(action)
    }

    private static func isSystemOverlayApp(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName else {
            return false
        }
        return MissionStrikeConfig.default.ignoredWindowOwners.contains(name)
    }

    private static func enclosingWindow(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let elem = current {
            if role(of: elem) == "AXWindow" { return elem }
            current = parent(of: elem)
        }
        return nil
    }
}
