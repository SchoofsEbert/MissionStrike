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

/// A window thumbnail in Mission Control.
struct WindowThumbnail: Equatable, Sendable {
    let window: AppWindow
    /// In AppKit screen coordinates.
    let frame: CGRect
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
    /// Frame of WindowManager's Spaces Bar, when it has one.
    func spacesBarFrame() -> CGRect?
    /// The buttons that can remove a Space (`AXRemoveDesktop`) with their frames: those in
    /// `bar`, or anywhere in WindowManager when nil.
    func desktops(in bar: Element?) -> [(element: Element, frame: CGRect)]
    /// The app window behind a thumbnail's CGWindowID; nil for system windows and for windows
    /// that aren't on screen, such as those on other Spaces.
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

    /// How deep tree walks go below WindowManager's application element.
    private static let walkDepthLimit = 12

    /// - Parameter clickPoint: Cursor position (`NSEvent.mouseLocation` space).
    static func resolve(clickPoint: CGPoint) -> Resolution? {
        performanceSignposter.withIntervalSignpost("Hit-test") {
            // Outside a session (Mission Control not seen open yet) a throwaway one does.
            resolve(clickPoint: clickPoint, in: MissionControlSession.current ?? MissionControlSession())
        }
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
                return nearestDesktop(in: environment.desktops(in: element), to: point)
            }
        }
        return nearestDesktop(in: environment.desktops(in: nil), to: point)
    }

    private static func isInSpacesStrip<Environment: HitTestEnvironment>(
        _ point: CGPoint,
        hit: Environment.Element?,
        in environment: Environment
    ) -> Bool {
        if let bar = environment.spacesBarFrame(), bar.insetBy(dx: 0, dy: -32).contains(point) {
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

    static func framed<Element: AccessibilityElement>(_ elements: [Element]) -> [(element: Element, frame: CGRect)] {
        elements.compactMap { element in element.frame.map { (element, $0) } }
    }

    /// Every element under `root` that can remove a Space. Thumbnails hold no Spaces, so
    /// their subtrees are skipped.
    static func removableDesktopButtons<Element: AccessibilityElement>(in root: Element) -> [Element] {
        var result: [Element] = []
        func walk(_ element: Element, depth: Int) {
            if element.hasAction("AXRemoveDesktop") {
                result.append(element)
            }
            guard depth < walkDepthLimit else { return }
            for child in element.walkStep().children {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return result
    }

    /// First element in `root`'s tree, depth first, with this title. Thumbnails' subtrees
    /// are skipped.
    static func firstDescendant<Element: AccessibilityElement>(of root: Element, titled title: String) -> Element? {
        func search(_ element: Element, depth: Int) -> Element? {
            let step = element.walkStep()
            if step.title == title { return element }
            guard depth < walkDepthLimit else { return nil }
            for child in step.children {
                if let found = search(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        return search(root, depth: 0)
    }

    // MARK: - Windows (wid)

    /// The app windows among the thumbnails under `root`, with their frames in AppKit screen
    /// coordinates (macOS 27+, where thumbnails carry a `wid`).
    static func windowThumbnails<Environment: HitTestEnvironment>(
        in root: Environment.Element,
        environment: Environment
    ) -> [WindowThumbnail] {
        thumbnailButtons(in: root).compactMap { button in
            guard let frame = button.element.frame,
                  let window = environment.appWindow(withID: button.windowID) else {
                return nil
            }
            let height = environment.mainDisplayHeight
            return WindowThumbnail(
                window: window,
                frame: environment.flipsY ? ScreenCoordinates.yFlipped(frame, mainDisplayHeight: height) : frame
            )
        }
    }

    /// Every window thumbnail under `root`, in tree order, each window once.
    static func thumbnailButtons<Element: AccessibilityElement>(in root: Element) -> [(element: Element, windowID: CGWindowID)] {
        var result: [(element: Element, windowID: CGWindowID)] = []
        var seen: Set<CGWindowID> = []
        func walk(_ element: Element, depth: Int) {
            let children = element.walkStep().children
            // Only childless elements can be thumbnails: walks leave out a thumbnail's subtree.
            if children.isEmpty {
                if let windowID = element.thumbnailWindowID, seen.insert(windowID).inserted {
                    result.append((element, windowID))
                }
                return
            }
            guard depth < walkDepthLimit else { return }
            for child in children {
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return result
    }

    private static func thumbnailWindow<Environment: HitTestEnvironment>(
        at point: CGPoint,
        hit: Environment.Element,
        in environment: Environment
    ) -> (AppWindow, CGRect)? {
        guard let button = ancestors(of: hit).first(where: { $0.thumbnailWindowID != nil }) else { return nil }
        // WindowManager keeps hidden thumbnails for the windows on other Spaces, and
        // Accessibility's hit-test can land on one of those. The thumbnail shown is then a sibling.
        for candidate in [button] + (button.parent?.children ?? []) {
            guard let windowID = candidate.thumbnailWindowID,
                  let frame = candidate.frame,
                  thumbnailHitArea(of: frame)?.contains(point) == true,
                  let window = environment.appWindow(withID: windowID) else {
                continue
            }
            return (window, frame)
        }
        return nil
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
