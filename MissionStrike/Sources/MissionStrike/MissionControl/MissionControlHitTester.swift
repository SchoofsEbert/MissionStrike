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
    /// `appWindow(withID:)` for many windows at once, keyed by CGWindowID.
    func appWindows(withIDs windowIDs: [CGWindowID]) -> [CGWindowID: AppWindow]
    /// Whether the element belongs to the Dock, WindowManager or another system overlay.
    func isSystemOverlay(_ element: Element) -> Bool
}

extension HitTestEnvironment {
    func appWindows(withIDs windowIDs: [CGWindowID]) -> [CGWindowID: AppWindow] {
        var windows: [CGWindowID: AppWindow] = [:]
        for windowID in windowIDs {
            windows[windowID] = appWindow(withID: windowID)
        }
        return windows
    }
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
        // Every step below starts from the element under the point and its ancestors; ask for
        // each of them once, and only as far up as a step looks.
        let hit = environment.element(at: point)
        let ancestors = Ancestors(of: hit)
        let stripElement = point.y < spaceButtonMaxY ? spacesStripElement(in: ancestors) : nil

        if let button = spaceButton(at: point, stripElement: stripElement, in: environment) {
            return HitResolution(target: .removeDesktop(button), point: point)
        }

        // Missed a desktop but still in the Spaces strip → do not close a window.
        if point.y < spacesStripMaxY, isInSpacesStrip(point, stripElement: stripElement, in: environment) {
            return nil
        }

        let thumbnail = enclosingThumbnail(in: ancestors)
        if let thumbnail, let (window, frame) = thumbnailWindow(at: point, button: thumbnail, in: environment) {
            return HitResolution(
                target: .window(pid: window.pid, ownerName: window.ownerName, windowID: window.windowID),
                point: point,
                thumbnailFrame: useFlip ? ScreenCoordinates.yFlipped(frame, mainDisplayHeight: height) : frame
            )
        }

        // Pre-wid Mission Control (≤26): enclosing AXWindow, unflipped path only.
        if !useFlip, thumbnail == nil, let hit, let window = legacyWindow(hit: hit, ancestors: ancestors, in: environment) {
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

    /// The part of the Spaces strip under the point, from the element there up.
    private enum StripElement<Element> {
        case desktop(Element)
        case bar(Element)
    }

    private static func spacesStripElement<Element>(in ancestors: Ancestors<Element>) -> StripElement<Element>? {
        for element in ancestors.prefix(ancestorLimit) {
            if element.hasAction("AXRemoveDesktop") {
                return .desktop(element)
            }
            if element.title == "Spaces Bar" {
                return .bar(element)
            }
        }
        return nil
    }

    /// Desktop button for `AXRemoveDesktop` at an AX-space point.
    private static func spaceButton<Environment: HitTestEnvironment>(
        at point: CGPoint,
        stripElement: StripElement<Environment.Element>?,
        in environment: Environment
    ) -> Environment.Element? {
        guard point.y < spaceButtonMaxY else { return nil }

        // Prefer live hit-test once the Spaces Bar is revealed.
        switch stripElement {
        case .desktop(let button):
            return button
        case .bar(let bar):
            return nearestDesktop(in: environment.desktops(in: bar), to: point)
        case nil:
            return nearestDesktop(in: environment.desktops(in: nil), to: point)
        }
    }

    private static func isInSpacesStrip<Environment: HitTestEnvironment>(
        _ point: CGPoint,
        stripElement: StripElement<Environment.Element>?,
        in environment: Environment
    ) -> Bool {
        if let bar = environment.spacesBarFrame(), bar.insetBy(dx: 0, dy: -32).contains(point) {
            return true
        }
        return stripElement != nil
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
        let buttons = thumbnailButtons(in: root)
        // One window-list call for all of them.
        let windows = environment.appWindows(withIDs: buttons.map(\.windowID))
        let height = environment.mainDisplayHeight
        return buttons.compactMap { button in
            guard let window = windows[button.windowID], let frame = button.element.frame else {
                return nil
            }
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

    /// The nearest thumbnail button at or above the element under the point, with its window ID.
    private static func enclosingThumbnail<Element>(in ancestors: Ancestors<Element>) -> (element: Element, windowID: CGWindowID)? {
        for element in ancestors.prefix(ancestorLimit) {
            if let windowID = element.thumbnailWindowID {
                return (element, windowID)
            }
        }
        return nil
    }

    private static func thumbnailWindow<Environment: HitTestEnvironment>(
        at point: CGPoint,
        button: (element: Environment.Element, windowID: CGWindowID),
        in environment: Environment
    ) -> (AppWindow, CGRect)? {
        func hit(_ windowID: CGWindowID, frame: CGRect?) -> (AppWindow, CGRect)? {
            guard let frame, thumbnailHitArea(of: frame)?.contains(point) == true,
                  let window = environment.appWindow(withID: windowID) else {
                return nil
            }
            return (window, frame)
        }
        if let found = hit(button.windowID, frame: button.element.frame) {
            return found
        }
        // WindowManager keeps hidden thumbnails for the windows on other Spaces, and
        // Accessibility's hit-test can land on one of those. The thumbnail shown is then a sibling.
        for candidate in button.element.parent?.children ?? [] where candidate != button.element {
            if let windowID = candidate.thumbnailWindowID, let found = hit(windowID, frame: candidate.frame) {
                return found
            }
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

    /// The enclosing `AXWindow`, for a hit outside every thumbnail.
    private static func legacyWindow<Environment: HitTestEnvironment>(
        hit: Environment.Element,
        ancestors: Ancestors<Environment.Element>,
        in environment: Environment
    ) -> Environment.Element? {
        guard !environment.isSystemOverlay(hit) else { return nil }
        return ancestors.first { $0.role == kAXWindowRole }
    }
}

// MARK: - Tree

/// An element and its ancestors, nearest first. Each parent is asked for once, and only when a
/// search gets that far: with Accessibility every step up is a round trip to the app.
final class Ancestors<Element: AccessibilityElement>: Sequence {
    private var elements: [Element]
    private var reachedRoot: Bool

    init(of element: Element?) {
        elements = element.map { [$0] } ?? []
        reachedRoot = element == nil
    }

    func makeIterator() -> AnyIterator<Element> {
        var index = 0
        return AnyIterator {
            defer { index += 1 }
            if index < self.elements.count {
                return self.elements[index]
            }
            guard !self.reachedRoot, let parent = self.elements.last?.parent else {
                self.reachedRoot = true
                return nil
            }
            self.elements.append(parent)
            return parent
        }
    }
}
