import AppKit
import ApplicationServices
import CoreGraphics

/// What a click or shortcut in Mission Control landed on.
struct HitResolution<Element: AccessibilityElement> {
    enum Target {
        case removeDesktop(Element)
        case window(pid: Int32, ownerName: String, windowID: CGWindowID)
        /// Pre-wid Mission Control (≤ macOS 26): the enclosing `AXWindow`.
        case legacyAXWindow(Element)
    }

    let target: Target
    /// Point in AX hit-test space (after any OS-gated Y-flip).
    let point: CGPoint
    /// Thumbnail frame in AppKit screen coordinates, when known (macOS 27+ window tiles).
    var thumbnailFrame: CGRect?
}

extension HitResolution: Sendable where Element: Sendable {}
extension HitResolution.Target: Sendable where Element: Sendable {}

/// An app window found in the window list.
struct AppWindow: Equatable, Sendable {
    let pid: Int32
    let ownerName: String
    let windowID: CGWindowID
}

/// What hit-testing needs besides the elements themselves. The live environment asks
/// Accessibility and the window list; tests answer from fake trees.
@MainActor
protocol HitTestEnvironment {
    associatedtype Element: AccessibilityElement

    /// macOS 27+ Mission Control reports click Y mirrored vs AX frames.
    var flipsY: Bool { get }
    /// Height of the primary display, for the Y-flip.
    var mainDisplayHeight: CGFloat { get }
    func element(at point: CGPoint) -> Element?
    /// WindowManager's Spaces Bar, when it has one.
    func spacesBar() -> Element?
    /// The buttons that can remove a Space (`AXRemoveDesktop`).
    func removableDesktopButtons() -> [Element]
    /// The app window behind a thumbnail's CGWindowID; nil for system windows.
    func appWindow(withID windowID: CGWindowID) -> AppWindow?
    /// Whether the element belongs to the Dock, WindowManager or another system overlay.
    func isSystemOverlay(_ element: Element) -> Bool
}

/// Hit testing for clicks, shortcuts and the hover badge in Mission Control. Asks other
/// apps through Accessibility, so it never runs inside the event tap callback.
///
/// **macOS 27+:** Mission Control thumbnails are WindowManager `AXButton`s with an
/// undocumented `wid` (CGWindowID). Click Y is mirrored vs AX frames, so we Y-flip once.
///
/// **macOS ≤26:** Dock-era UI exposes real `AXWindow`s; no Y-flip, legacy close path.
@MainActor
enum MissionControlHitTester {
    typealias Resolution = HitResolution<AXElement>
    typealias Target = Resolution.Target

    /// Reject AX padding around thumbnail buttons (greedy hit targets on 27).
    static let thumbnailEdgeInsetFraction: CGFloat = 0.10

    /// Below this Y (AX space), treat the click as Spaces-strip only — never a window.
    static let spacesStripMaxY: CGFloat = 140
    /// Below this Y (AX space), a click may be on a Space's button.
    static let spaceButtonMaxY: CGFloat = spacesStripMaxY + 40

    /// How many elements, from the one under the pointer up, to search for a Space or thumbnail.
    private static let ancestorLimit = 8

    // MARK: - Public API

    /// - Parameter clickPoint: Cursor position (`NSEvent.mouseLocation` space).
    static func resolve(clickPoint: CGPoint) -> Resolution? {
        resolve(clickPoint: clickPoint, in: LiveHitTestEnvironment())
    }

    static func resolve<Environment: HitTestEnvironment>(
        clickPoint: CGPoint,
        in environment: Environment
    ) -> HitResolution<Environment.Element>? {
        let useFlip = environment.flipsY
        let height = environment.mainDisplayHeight
        let point = useFlip ? ScreenCoordinates.yFlipped(clickPoint, mainDisplayHeight: height) : clickPoint
        // Every step below starts from the element under the point; ask for it once.
        let hit = environment.element(at: point)

        if let button = spaceButton(at: point, hit: hit, in: environment) {
            return HitResolution(target: .removeDesktop(button), point: point)
        }

        // Missed a desktop but still in the Spaces strip → do not close a window.
        if point.y < spacesStripMaxY, isInSpacesStrip(point, hit: hit, in: environment) {
            return nil
        }

        if let hit, let (window, frame) = thumbnailWindow(at: point, hit: hit, in: environment) {
            return HitResolution(
                target: .window(pid: window.pid, ownerName: window.ownerName, windowID: window.windowID),
                point: point,
                thumbnailFrame: useFlip ? ScreenCoordinates.yFlipped(frame, mainDisplayHeight: height) : frame
            )
        }

        // Pre-wid Mission Control (≤26): enclosing AXWindow, unflipped path only.
        if !useFlip, let hit, let window = legacyWindow(hit: hit, in: environment) {
            return HitResolution(target: .legacyAXWindow(window), point: point)
        }
        return nil
    }

    // MARK: - Y-flip gate

    /// macOS 27+ Mission Control reports click Y mirrored vs AX frames.
    nonisolated static func shouldYFlipForMissionControl() -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    // MARK: - Spaces

    /// Desktop button for `AXRemoveDesktop` at an AX-space point.
    private static func spaceButton<Environment: HitTestEnvironment>(
        at point: CGPoint,
        hit: Environment.Element?,
        in environment: Environment
    ) -> Environment.Element? {
        guard point.y < spaceButtonMaxY else { return nil }

        // Prefer live hit-test once the Spaces Bar is revealed.
        for element in ancestors(of: hit) {
            if element.hasAction("AXRemoveDesktop") {
                return element
            }
            if element.title == "Spaces Bar" {
                return nearestDesktop(in: framed(removableDesktopButtons(in: element)), to: point)
            }
        }
        return nearestDesktop(in: framed(environment.removableDesktopButtons()), to: point)
    }

    private static func isInSpacesStrip<Environment: HitTestEnvironment>(
        _ point: CGPoint,
        hit: Environment.Element?,
        in environment: Environment
    ) -> Bool {
        if let bar = environment.spacesBar()?.frame, bar.insetBy(dx: 0, dy: -32).contains(point) {
            return true
        }
        return ancestors(of: hit).contains { $0.title == "Spaces Bar" || $0.hasAction("AXRemoveDesktop") }
    }

    /// Nearest desktop whose inflated frame contains the point, else nil.
    static func nearestDesktop<Element>(in desktops: [(element: Element, frame: CGRect)], to point: CGPoint) -> Element? {
        desktops
            // AX frames are smaller than the visible Space preview.
            .filter { $0.frame.insetBy(dx: -16, dy: -28).contains(point) }
            .min { distance($0.frame, point) < distance($1.frame, point) }?
            .element
    }

    private static func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(frame.midX - point.x, frame.midY - point.y)
    }

    private static func framed<Element: AccessibilityElement>(_ elements: [Element]) -> [(element: Element, frame: CGRect)] {
        elements.compactMap { element in element.frame.map { (element, $0) } }
    }

    /// Every element under `root` that can remove a Space.
    static func removableDesktopButtons<Element: AccessibilityElement>(in root: Element) -> [Element] {
        var result: [Element] = []
        func walk(_ element: Element) {
            if element.hasAction("AXRemoveDesktop") {
                result.append(element)
            }
            for child in element.children {
                walk(child)
            }
        }
        walk(root)
        return result
    }

    /// First element in `root`'s tree, depth first, that matches.
    static func descendant<Element: AccessibilityElement>(
        in root: Element,
        matching predicate: (Element) -> Bool
    ) -> Element? {
        if predicate(root) { return root }
        for child in root.children {
            if let found = descendant(in: child, matching: predicate) {
                return found
            }
        }
        return nil
    }

    // MARK: - Windows (wid)

    private static func thumbnailWindow<Environment: HitTestEnvironment>(
        at point: CGPoint,
        hit: Environment.Element,
        in environment: Environment
    ) -> (AppWindow, CGRect)? {
        guard let button = ancestors(of: hit).first(where: { $0.thumbnailWindowID != nil }),
              let windowID = button.thumbnailWindowID,
              let buttonFrame = button.frame,
              thumbnailHitArea(of: buttonFrame)?.contains(point) == true,
              let window = environment.appWindow(withID: windowID) else {
            return nil
        }
        return (window, buttonFrame)
    }

    /// The part of a thumbnail button that counts as a hit, or nil when too small to trust.
    static func thumbnailHitArea(of buttonFrame: CGRect) -> CGRect? {
        let inset = buttonFrame.insetBy(
            dx: buttonFrame.width * thumbnailEdgeInsetFraction,
            dy: buttonFrame.height * thumbnailEdgeInsetFraction
        )
        return inset.width > 8 && inset.height > 8 ? inset : nil
    }

    // MARK: - Legacy ≤26

    private static func legacyWindow<Environment: HitTestEnvironment>(
        hit: Environment.Element,
        in environment: Environment
    ) -> Environment.Element? {
        guard !ancestors(of: hit).contains(where: { $0.thumbnailWindowID != nil }),
              !environment.isSystemOverlay(hit) else {
            return nil
        }
        var current: Environment.Element? = hit
        while let element = current {
            if element.role == kAXWindowRole { return element }
            current = element.parent
        }
        return nil
    }

    // MARK: - Tree

    /// The element and its ancestors, nearest first, `ancestorLimit` at most.
    private static func ancestors<Element: AccessibilityElement>(of element: Element?) -> [Element] {
        var result: [Element] = []
        var current = element
        while let element = current, result.count < ancestorLimit {
            result.append(element)
            current = element.parent
        }
        return result
    }
}

/// Hit testing against the live Accessibility tree and window list.
@MainActor
struct LiveHitTestEnvironment: HitTestEnvironment {
    var flipsY: Bool { MissionControlHitTester.shouldYFlipForMissionControl() }

    var mainDisplayHeight: CGFloat { ScreenCoordinates.mainDisplayHeight }

    func element(at point: CGPoint) -> AXElement? {
        AXElement.at(point)
    }

    func spacesBar() -> AXElement? {
        guard let root = Self.windowManager() else { return nil }
        return MissionControlHitTester.descendant(in: root) { $0.title == "Spaces Bar" }
    }

    func removableDesktopButtons() -> [AXElement] {
        guard let root = Self.windowManager() else { return [] }
        return MissionControlHitTester.removableDesktopButtons(in: root)
    }

    func appWindow(withID windowID: CGWindowID) -> AppWindow? {
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
            return AppWindow(pid: found.pid, ownerName: found.ownerName, windowID: found.windowID)
        }
        return nil
    }

    func isSystemOverlay(_ element: AXElement) -> Bool {
        guard let pid = element.pid,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName else {
            return false
        }
        return MissionStrikeConfig.default.ignoredWindowOwners.contains(name)
    }

    private static func windowManager() -> AXElement? {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: {
            $0.localizedName == "WindowManager" || $0.bundleIdentifier == "com.apple.WindowManager"
        }) else {
            return nil
        }
        return AXElement.application(app.processIdentifier)
    }
}
