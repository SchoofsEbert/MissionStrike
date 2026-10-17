@testable import MissionStrike
import ApplicationServices
import CoreGraphics
import Testing

/// An Accessibility element in a hand-built tree.
final class FakeElement: AccessibilityElement {
    var role: String?
    var title: String?
    var frame: CGRect?
    var thumbnailWindowID: CGWindowID?
    var actions: Set<String> = []
    weak var parent: FakeElement?
    private(set) var children: [FakeElement] = []

    init(role: String? = nil, title: String? = nil, frame: CGRect? = nil, wid: CGWindowID? = nil, actions: Set<String> = []) {
        self.role = role
        self.title = title
        self.frame = frame
        self.thumbnailWindowID = wid
        self.actions = actions
    }

    @discardableResult
    func add(_ child: FakeElement) -> FakeElement {
        child.parent = self
        children.append(child)
        return child
    }

    func hasAction(_ action: String) -> Bool {
        actions.contains(action)
    }

    static func == (lhs: FakeElement, rhs: FakeElement) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Hit-tests a fake tree: the element at a point is the deepest one whose frame holds it.
@MainActor
private struct FakeEnvironment: HitTestEnvironment {
    var root: FakeElement
    var flipsY = false
    var mainDisplayHeight: CGFloat = 1000
    var windows: [CGWindowID: AppWindow] = [:]
    var systemOverlays: [FakeElement] = []

    func element(at point: CGPoint) -> FakeElement? {
        func deepest(_ element: FakeElement) -> FakeElement? {
            guard element.frame?.contains(point) ?? true else { return nil }
            for child in element.children.reversed() {
                if let hit = deepest(child) { return hit }
            }
            return element.frame == nil ? nil : element
        }
        return deepest(root)
    }

    func spacesBarFrame() -> CGRect? {
        MissionControlHitTester.firstDescendant(of: root, titled: "Spaces Bar")?.frame
    }

    func desktops(in bar: FakeElement?) -> [(element: FakeElement, frame: CGRect)] {
        MissionControlHitTester.framed(MissionControlHitTester.removableDesktopButtons(in: bar ?? root))
    }

    func appWindow(withID windowID: CGWindowID) -> AppWindow? {
        windows[windowID]
    }

    func isSystemOverlay(_ element: FakeElement) -> Bool {
        systemOverlays.contains { $0 === element }
    }
}

/// A Mission Control screen: a Spaces Bar with two Spaces along the top and one window thumbnail.
@MainActor
private struct MissionControlScreen {
    let root = FakeElement(role: "AXApplication")
    let bar: FakeElement
    let desktop1: FakeElement
    let desktop2: FakeElement
    let thumbnail: FakeElement
    var environment: FakeEnvironment

    init() {
        bar = root.add(FakeElement(role: "AXGroup", title: "Spaces Bar", frame: CGRect(x: 0, y: 20, width: 1000, height: 80)))
        desktop1 = bar.add(Self.desktop(CGRect(x: 100, y: 30, width: 160, height: 60)))
        desktop2 = bar.add(Self.desktop(CGRect(x: 300, y: 30, width: 160, height: 60)))
        thumbnail = root.add(FakeElement(role: "AXButton", frame: CGRect(x: 100, y: 200, width: 400, height: 300), wid: 42))
        thumbnail.add(FakeElement(role: "AXImage", frame: CGRect(x: 150, y: 250, width: 300, height: 200)))
        environment = FakeEnvironment(root: root, windows: [42: AppWindow(pid: 7, ownerName: "Notes", windowID: 42)])
    }

    static func desktop(_ frame: CGRect) -> FakeElement {
        FakeElement(role: "AXButton", frame: frame, actions: ["AXRemoveDesktop"])
    }

    func resolve(_ point: CGPoint) -> HitResolution<FakeElement>? {
        MissionControlHitTester.resolve(clickPoint: point, in: environment)
    }
}

@MainActor
@Suite("Mission Control Hit Testing")
struct HitTesterTests {

    @Test("The middle of a thumbnail resolves to its window")
    func thumbnailHit() {
        let screen = MissionControlScreen()
        let hit = screen.resolve(CGPoint(x: 300, y: 350))
        guard case .window(let pid, let owner, let windowID) = hit?.target else {
            Issue.record("Expected a window, got \(String(describing: hit?.target))")
            return
        }
        #expect(pid == 7 && owner == "Notes" && windowID == 42)
        #expect(hit?.thumbnailFrame == CGRect(x: 100, y: 200, width: 400, height: 300))
    }

    @Test("The padding along a thumbnail's edge is not a hit")
    func thumbnailInset() {
        let screen = MissionControlScreen()
        #expect(screen.resolve(CGPoint(x: 110, y: 350)) == nil)
        #expect(screen.resolve(CGPoint(x: 300, y: 495)) == nil)
        #expect(MissionControlHitTester.thumbnailHitArea(of: CGRect(x: 100, y: 200, width: 400, height: 300))
            == CGRect(x: 140, y: 230, width: 320, height: 240))
        #expect(MissionControlHitTester.thumbnailHitArea(of: CGRect(x: 0, y: 0, width: 10, height: 100)) == nil)
    }

    @Test("A thumbnail of a system window is not a hit")
    func systemWindow() {
        var screen = MissionControlScreen()
        screen.environment.windows = [:]
        #expect(screen.resolve(CGPoint(x: 300, y: 350)) == nil)
    }

    @Test("Clicking a Space's button resolves to that Space")
    func spaceButton() {
        let screen = MissionControlScreen()
        guard case .removeDesktop(let button) = screen.resolve(CGPoint(x: 380, y: 60))?.target else {
            Issue.record("Expected a Space")
            return
        }
        #expect(button === screen.desktop2)
    }

    @Test("Near a Space, the nearest one within reach wins")
    func nearestSpace() {
        let screen = MissionControlScreen()
        // Just below desktop 1's frame, inside its inflated hit frame; the bar is under the point.
        guard case .removeDesktop(let button) = screen.resolve(CGPoint(x: 180, y: 100))?.target else {
            Issue.record("Expected a Space")
            return
        }
        #expect(button === screen.desktop1)

        let desktops = [(element: "a", frame: CGRect(x: 0, y: 0, width: 100, height: 50)),
                        (element: "b", frame: CGRect(x: 110, y: 0, width: 100, height: 50))]
        #expect(MissionControlHitTester.nearestDesktop(in: desktops, to: CGPoint(x: 104, y: 25)) == "a")
        #expect(MissionControlHitTester.nearestDesktop(in: desktops, to: CGPoint(x: 107, y: 25)) == "b")
        #expect(MissionControlHitTester.nearestDesktop(in: desktops, to: CGPoint(x: 500, y: 25)) == nil)
    }

    @Test("In the Spaces strip but off every Space, nothing is hit — not even a window below")
    func spacesStrip() {
        let screen = MissionControlScreen()
        screen.root.add(FakeElement(role: "AXButton", frame: CGRect(x: 600, y: 60, width: 300, height: 200), wid: 43))
        var environment = screen.environment
        environment.windows[43] = AppWindow(pid: 8, ownerName: "Mail", windowID: 43)
        let point = CGPoint(x: 750, y: 120)
        #expect(point.y < MissionControlHitTester.spacesStripMaxY)
        #expect(MissionControlHitTester.resolve(clickPoint: point, in: environment) == nil)
        // Below the strip the same thumbnail is a hit.
        #expect(MissionControlHitTester.resolve(clickPoint: CGPoint(x: 750, y: 160), in: environment) != nil)
    }

    @Test("Spaces are only looked for near the top")
    func spaceButtonThreshold() {
        let screen = MissionControlScreen()
        screen.root.add(MissionControlScreen.desktop(CGRect(x: 600, y: 600, width: 100, height: 60)))
        #expect(screen.resolve(CGPoint(x: 650, y: 630)) == nil)
    }

    @Test("Tree walks skip thumbnails' subtrees")
    func prunedWalk() {
        let screen = MissionControlScreen()
        screen.thumbnail.add(MissionControlScreen.desktop(CGRect(x: 120, y: 220, width: 10, height: 10)))
        screen.thumbnail.add(FakeElement(role: "AXGroup", title: "Spaces Bar"))
        let buttons = MissionControlHitTester.removableDesktopButtons(in: screen.root)
        #expect(buttons.count == 2)
        #expect(MissionControlHitTester.firstDescendant(of: screen.thumbnail, titled: "Spaces Bar") == nil)
    }

    @Test("Every thumbnail is found once, in tree order, without looking inside thumbnails")
    func thumbnailButtons() {
        let screen = MissionControlScreen()
        let group = screen.root.add(FakeElement(role: "AXGroup", frame: CGRect(x: 0, y: 600, width: 1000, height: 300)))
        let second = group.add(FakeElement(role: "AXButton", frame: CGRect(x: 100, y: 620, width: 200, height: 150), wid: 43))
        group.add(FakeElement(role: "AXButton", frame: CGRect(x: 400, y: 620, width: 200, height: 150), wid: 42))
        screen.thumbnail.add(FakeElement(role: "AXButton", frame: CGRect(x: 150, y: 250, width: 50, height: 50), wid: 44))

        let found = MissionControlHitTester.thumbnailButtons(in: screen.root)
        #expect(found.map(\.windowID) == [42, 43])
        #expect(found.first?.element === screen.thumbnail)
        #expect(found.last?.element === second)
    }

    @Test("Window thumbnails leave out system windows and come back in AppKit coordinates on 27")
    func windowThumbnails() {
        var screen = MissionControlScreen()
        screen.root.add(FakeElement(role: "AXButton", frame: CGRect(x: 600, y: 200, width: 300, height: 200), wid: 99))
        let notes = AppWindow(pid: 7, ownerName: "Notes", windowID: 42)
        #expect(MissionControlHitTester.windowThumbnails(in: screen.root, environment: screen.environment)
            == [WindowThumbnail(window: notes, frame: CGRect(x: 100, y: 200, width: 400, height: 300))])

        screen.environment.flipsY = true
        #expect(MissionControlHitTester.windowThumbnails(in: screen.root, environment: screen.environment)
            == [WindowThumbnail(window: notes, frame: CGRect(x: 100, y: 500, width: 400, height: 300))])
    }

    @Test("The background menu counts the windows it closes")
    func windowsHereTitle() {
        #expect(MissionControlContextMenu.windowsHereTitle("Close", count: 7) == "Close All 7 Windows Here")
        #expect(MissionControlContextMenu.windowsHereTitle("Minimize", count: 1) == "Minimize 1 Window Here")
    }

    @Test("macOS 27: the click is flipped into AX space and the thumbnail frame flipped back")
    func yFlip() {
        var screen = MissionControlScreen()
        screen.environment.flipsY = true
        let hit = screen.resolve(CGPoint(x: 300, y: 650))
        #expect(hit?.point == CGPoint(x: 300, y: 350))
        #expect(hit?.thumbnailFrame == CGRect(x: 100, y: 500, width: 400, height: 300))
    }

    @Test("Pre-27 Mission Control falls back to the enclosing AXWindow, never on 27")
    func legacyWindow() {
        let root = FakeElement(role: "AXApplication")
        let window = root.add(FakeElement(role: kAXWindowRole, frame: CGRect(x: 0, y: 300, width: 500, height: 400)))
        window.add(FakeElement(role: "AXGroup", frame: CGRect(x: 10, y: 310, width: 100, height: 100)))
        var environment = FakeEnvironment(root: root)

        let hit = MissionControlHitTester.resolve(clickPoint: CGPoint(x: 50, y: 350), in: environment)
        guard case .legacyAXWindow(let found) = hit?.target else {
            Issue.record("Expected the legacy window")
            return
        }
        #expect(found === window)

        environment.flipsY = true
        environment.mainDisplayHeight = 1000
        #expect(MissionControlHitTester.resolve(clickPoint: CGPoint(x: 50, y: 650), in: environment) == nil)
    }

    @Test("System overlays are never legacy windows")
    func legacySystemOverlay() {
        let root = FakeElement(role: "AXApplication")
        let window = root.add(FakeElement(role: kAXWindowRole, frame: CGRect(x: 0, y: 300, width: 500, height: 400)))
        let environment = FakeEnvironment(root: root, systemOverlays: [window])
        #expect(MissionControlHitTester.resolve(clickPoint: CGPoint(x: 50, y: 350), in: environment) == nil)
    }
}
