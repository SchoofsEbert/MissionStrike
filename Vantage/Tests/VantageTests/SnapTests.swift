@testable import Vantage
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("Snap Layout")
struct SnapLayoutTests {
    /// A 1440×875 visible area below a 25-point menu bar.
    private let area = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test("Each side steps through half, a third and two-thirds")
    func sideFrames() {
        #expect(SnapLayout.frame(for: .left, step: 0, in: area) == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(SnapLayout.frame(for: .left, step: 1, in: area) == CGRect(x: 0, y: 25, width: 480, height: 875))
        #expect(SnapLayout.frame(for: .left, step: 2, in: area) == CGRect(x: 0, y: 25, width: 960, height: 875))
        #expect(SnapLayout.frame(for: .right, step: 1, in: area) == CGRect(x: 960, y: 25, width: 480, height: 875))
        #expect(SnapLayout.frame(for: .top, step: 0, in: area) == CGRect(x: 0, y: 25, width: 1440, height: 438))
        #expect(SnapLayout.frame(for: .bottom, step: 0, in: area) == CGRect(x: 0, y: 462, width: 1440, height: 438))
        #expect(SnapLayout.frame(for: .maximize, step: 0, in: area) == area)
    }

    @Test("The rest beside a snapped window fills the area exactly")
    func rests() {
        for action in [SnapAction.left, .right, .top, .bottom] {
            for step in 0..<SnapLayout.stepCount(for: action) {
                let snapped = SnapLayout.frame(for: action, step: step, in: area)
                guard let rest = SnapLayout.rest(beside: snapped, of: action, in: area) else {
                    Issue.record("No rest for \(action) step \(step)")
                    continue
                }
                #expect(snapped.width * snapped.height + rest.width * rest.height == area.width * area.height)
                #expect(snapped.union(rest) == area)
            }
        }
        #expect(SnapLayout.rest(beside: area, of: .maximize, in: area) == nil)
    }

    @Test("The rest starts where the snapped window ends, and too little rest offers nothing")
    func restFromTakenFrame() {
        let wide = CGRect(x: 0, y: 25, width: 900, height: 875)
        #expect(SnapLayout.rest(beside: wide, of: .left, in: area) == CGRect(x: 900, y: 25, width: 540, height: 875))
        let tooWide = CGRect(x: 0, y: 25, width: 1300, height: 875)
        #expect(SnapLayout.rest(beside: tooWide, of: .left, in: area) == nil)
    }

    @Test("A repeated press on the same window moves to the next step, wrapping around")
    func cycling() {
        let taken = CGRect(x: 0, y: 25, width: 714, height: 870)
        let last = SnapRecord(action: .left, step: 0, windowID: 7, frame: taken)
        #expect(SnapLayout.nextStep(for: .left, windowFrame: taken, area: area, last: last, windowID: 7) == 1)

        let lastStep = SnapRecord(action: .left, step: 2, windowID: 7, frame: taken)
        #expect(SnapLayout.nextStep(for: .left, windowFrame: taken, area: area, last: lastStep, windowID: 7) == 0)
    }

    @Test("Another window, another action or a moved window starts over")
    func startingOver() {
        let taken = CGRect(x: 0, y: 25, width: 714, height: 870)
        let last = SnapRecord(action: .left, step: 0, windowID: 7, frame: taken)
        #expect(SnapLayout.nextStep(for: .left, windowFrame: taken, area: area, last: last, windowID: 8) == 0)
        #expect(SnapLayout.nextStep(for: .right, windowFrame: taken, area: area, last: last, windowID: 7) == 0)
        let moved = taken.offsetBy(dx: 40, dy: 0)
        #expect(SnapLayout.nextStep(for: .left, windowFrame: moved, area: area, last: last, windowID: 7) == 0)
    }

    @Test("A window another tool already snapped moves on from where it is")
    func snappedElsewhere() {
        let half = SnapLayout.frame(for: .left, step: 0, in: area)
        #expect(SnapLayout.nextStep(for: .left, windowFrame: half, area: area, last: nil, windowID: 1) == 1)
        #expect(SnapLayout.nextStep(for: .maximize, windowFrame: area, area: area, last: nil, windowID: 1) == 0)
    }

    @Test("A window that won't take the asked size still hugs the right and bottom edges")
    func anchoring() {
        let fixed = CGRect(x: 720, y: 25, width: 500, height: 875)
        let rightHalf = SnapLayout.frame(for: .right, step: 0, in: area)
        #expect(SnapLayout.anchored(fixed, for: .right, target: rightHalf, in: area) == CGRect(x: 940, y: 25, width: 500, height: 875))

        let tooWide = CGRect(x: 960, y: 25, width: 1600, height: 875)
        #expect(SnapLayout.anchored(tooWide, for: .right, target: rightHalf, in: area).minX == area.minX)

        let rounded = CGRect(x: 0, y: 462, width: 1440, height: 430)
        let bottomHalf = SnapLayout.frame(for: .bottom, step: 0, in: area)
        #expect(SnapLayout.anchored(rounded, for: .bottom, target: bottomHalf, in: area).maxY == area.maxY)

        let leftHalf = SnapLayout.frame(for: .left, step: 0, in: area)
        #expect(SnapLayout.anchored(fixed, for: .left, target: leftHalf, in: area).origin == leftHalf.origin)
    }

    @Test("A plan picks the window's screen and step, and has nowhere to go for a display move on one screen")
    func plans() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let plan = SnapLayout.plan(.left, windowFrame: window, areas: [area], last: nil, windowID: 1)
        #expect(plan?.frame == SnapLayout.frame(for: .left, step: 0, in: area))
        #expect(plan?.area == area)
        #expect(SnapLayout.plan(.nextDisplay, windowFrame: window, areas: [area], last: nil, windowID: 1) == nil)
        #expect(SnapLayout.plan(.left, windowFrame: window, areas: [], last: nil, windowID: 1) == nil)
    }

    @Test("A window snaps on the screen it overlaps most")
    func screenChoice() {
        let builtIn = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let external = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
        let window = CGRect(x: 1300, y: 100, width: 800, height: 600)
        #expect(SnapLayout.area(for: window, in: [builtIn, external]) == external)
        let offScreen = CGRect(x: -5000, y: 0, width: 100, height: 100)
        #expect(SnapLayout.area(for: offScreen, in: [builtIn, external]) == builtIn)
        #expect(SnapLayout.area(for: window, in: []) == nil)
    }
}

@Suite("Moving Between Displays")
struct SnapDisplayTests {
    private let builtIn = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let external = CGRect(x: 1440, y: 0, width: 2560, height: 1400)

    @Test("A snapped window stays snapped the same way on the next screen")
    func keepsPlace() {
        let leftHalf = SnapLayout.frame(for: .left, step: 0, in: builtIn)
        #expect(SnapLayout.frame(movingToDisplay: .nextDisplay, from: leftHalf, in: [builtIn, external])
            == SnapLayout.frame(for: .left, step: 0, in: external))
    }

    @Test("Next and previous wrap around the screens from left to right")
    func wraps() {
        let window = CGRect(x: 1600, y: 100, width: 800, height: 600)
        let screens = [external, builtIn]
        #expect(SnapLayout.frame(movingToDisplay: .nextDisplay, from: window, in: screens).map(builtIn.contains) == true)
        #expect(SnapLayout.frame(movingToDisplay: .previousDisplay, from: window, in: screens).map(builtIn.contains) == true)
        #expect(SnapLayout.frame(movingToDisplay: .nextDisplay, from: window, in: [external]) == nil)
    }
}

@Suite("Key Shortcuts")
struct KeyShortcutTests {
    @Test("A shortcut survives storage, without flags that aren't modifiers")
    func storage() {
        let shortcut = KeyShortcut(keyCode: Int64(kVK_LeftArrow), flags: [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad])
        #expect(shortcut.flags == [.maskControl, .maskAlternate])
        #expect(KeyShortcut(storage: shortcut.storage) == shortcut)
        #expect(KeyShortcut(storage: "") == nil)
        #expect(KeyShortcut(storage: "left") == nil)
    }

    @Test("Shortcuts need ⌘, ⌥ or ⌃, except on function keys")
    func allowed() {
        #expect(KeyShortcut(keyCode: Int64(kVK_LeftArrow), flags: [.maskControl]).isAllowed)
        #expect(!KeyShortcut(keyCode: Int64(kVK_ANSI_A), flags: []).isAllowed)
        #expect(!KeyShortcut(keyCode: Int64(kVK_ANSI_A), flags: [.maskShift]).isAllowed)
        #expect(KeyShortcut(keyCode: Int64(kVK_F5), flags: []).isAllowed)
    }

    @Test("Shortcuts read like menus show them")
    func display() {
        #expect(KeyShortcut(keyCode: Int64(kVK_LeftArrow), flags: [.maskAlternate, .maskControl]).displayString == "⌃⌥←")
        #expect(KeyShortcut(keyCode: Int64(kVK_Return), flags: [.maskCommand, .maskShift]).displayString == "⇧⌘↩")
        #expect(KeyShortcut(keyCode: Int64(kVK_F2), flags: []).displayString == "F2")
    }

    @Test("Keys are looked up with their modifiers, ignoring the rest of the flags")
    func lookup() {
        let shortcuts = SnapShortcuts(SnapShortcuts.defaults)
        let arrowFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
        #expect(shortcuts.action(keyCode: Int64(kVK_LeftArrow), flags: arrowFlags) == .left)
        #expect(shortcuts.action(keyCode: Int64(kVK_LeftArrow), flags: [.maskControl]) == nil)
        #expect(shortcuts.action(keyCode: Int64(kVK_ANSI_A), flags: [.maskControl, .maskAlternate]) == nil)
    }

    @Test("Shortcuts that would take a key from typing are dropped, and a shared one goes to the first action")
    func invalidAndShared() {
        let plainA = KeyShortcut(keyCode: Int64(kVK_ANSI_A), flags: [])
        let shared = KeyShortcut(keyCode: Int64(kVK_ANSI_K), flags: [.maskCommand, .maskAlternate])
        let shortcuts = SnapShortcuts([.left: plainA, .right: shared, .maximize: shared])
        #expect(shortcuts.action(keyCode: Int64(kVK_ANSI_A), flags: []) == nil)
        #expect(shortcuts.action(keyCode: Int64(kVK_ANSI_K), flags: [.maskCommand, .maskAlternate]) == .right)
    }

    @Test("Snapping is off by default, and its shortcuts load once it's on")
    func settings() throws {
        let name = "VantageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        SettingKey.registerDefaults(in: defaults)
        #expect(Settings(defaults).snapShortcuts.isEmpty)

        defaults.set(true, forKey: SettingKey.enableWindowSnapping.rawValue)
        #expect(Settings(defaults).snapShortcuts == SnapShortcuts(SnapShortcuts.defaults))

        #expect(Settings(defaults).snapShortcuts.action(keyCode: Int64(kVK_DownArrow), flags: [.maskControl, .maskAlternate]) == .restore)

        let down = KeyShortcut(keyCode: Int64(kVK_DownArrow), flags: [.maskControl, .maskAlternate])
        defaults.set(down.storage, forKey: SettingKey.snapBottomShortcut.rawValue)
        defaults.set("", forKey: SettingKey.snapMaximizeShortcut.rawValue)
        let snapshot = Settings(defaults).snapShortcuts
        #expect(snapshot.action(keyCode: Int64(kVK_UpArrow), flags: [.maskControl, .maskAlternate]) == nil)
        #expect(snapshot.action(keyCode: Int64(kVK_DownArrow), flags: [.maskControl, .maskAlternate]) == .bottom)
    }
}

@Suite("Snap Assist")
struct SnapAssistTests {
    private func window(_ id: CGWindowID, pid: pid_t = 10, owner: String = "Notes", layer: Int = 0,
                        size: CGSize = CGSize(width: 600, height: 400), alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation as NSDictionary
        ]
    }

    @Test("Offers regular apps' windows front to back, without the snapped one, our own, system windows or helpers")
    func candidates() {
        let list = [
            window(1), window(2, pid: 11, owner: "Safari"), window(3, owner: "Dock"),
            window(4, layer: 25), window(5, size: CGSize(width: 30, height: 30)), window(6, alpha: 0),
            window(7, pid: 99, owner: "Vantage"), window(8, pid: 12, owner: "Mail")
        ]
        let snapped = SnapAssistModel.Snapped(windowID: 1, pid: 10, frame: .zero)
        let offered = SnapAssistModel.candidates(in: list, excluding: snapped, ownPID: 99, isRegularApp: { $0 != 12 })
        #expect(offered.map(\.windowID) == [2])
        #expect(offered.first?.appName == "Safari")
    }

    @Test("At most eighteen windows, so nine are left once Accessibility weeds some out")
    func nineAtMost() {
        let list = (1...24).map { window(CGWindowID($0)) }
        let snapped = SnapAssistModel.Snapped(windowID: nil, pid: 1, frame: .zero)
        #expect(SnapAssistModel.candidates(in: list, excluding: snapped, ownPID: 99, isRegularApp: { _ in true }).count == 18)
    }

    @Test("Without its window ID, the snapped window is recognised by its app and frame")
    func snappedWithoutID() {
        let list = [window(1), window(2, size: CGSize(width: 300, height: 300))]
        let frame = CGRect(origin: .zero, size: CGSize(width: 600, height: 400))
        let snapped = SnapAssistModel.Snapped(windowID: nil, pid: 10, frame: frame)
        let offered = SnapAssistModel.candidates(in: list, excluding: snapped, ownPID: 99, isRegularApp: { _ in true })
        #expect(offered.map(\.windowID) == [2])
    }

    @Test("Cards sit inside the area without overlapping, in a grid that fits")
    func cards() {
        let area = CGRect(x: 720, y: 0, width: 720, height: 900)
        let frames = SnapAssistModel.cardFrames(count: 5, in: area)
        #expect(frames.count == 5)
        for (index, frame) in frames.enumerated() {
            #expect(area.contains(frame))
            for other in frames[(index + 1)...] {
                #expect(!frame.intersects(other))
            }
        }
        // Two columns make the largest cells in this half; the fifth window is centred below.
        #expect(Set(frames.map(\.minY)).count == 3)
        #expect(frames[0].minY == frames[1].minY)
        #expect(abs(frames[4].midX - area.midX) <= 1)

        let narrow = CGRect(x: 0, y: 0, width: 300, height: 900)
        #expect(SnapAssistModel.cardFrames(count: 3, in: narrow).allSatisfy { narrow.contains($0) })
        #expect(SnapAssistModel.cardFrames(count: 0, in: area).isEmpty)
    }

    @Test("A thumbnail keeps its window's shape, centred above the label")
    func thumbnails() {
        let cell = CGSize(width: 400, height: 330)
        let wide = SnapAssistModel.thumbnailFrame(for: CGSize(width: 1600, height: 900), in: cell)
        #expect(wide == CGRect(x: 0, y: 38, width: 400, height: 225))
        let tall = SnapAssistModel.thumbnailFrame(for: CGSize(width: 500, height: 1000), in: cell)
        #expect(tall.height == 300)
        #expect(tall.midX == 200)
        let small = SnapAssistModel.thumbnailFrame(for: CGSize(width: 200, height: 100), in: cell)
        #expect(small.size == CGSize(width: 200, height: 100))
    }

    @Test("Arrows move the ring to the nearest card that way, starting at the first")
    func navigation() {
        // Two columns, three rows, the fifth card centred below.
        let cards = SnapAssistModel.cardFrames(count: 5, in: CGRect(x: 720, y: 0, width: 720, height: 900))
        #expect(SnapAssistModel.card(from: nil, moving: .down, in: cards) == 0)
        #expect(SnapAssistModel.card(from: 0, moving: .right, in: cards) == 1)
        #expect(SnapAssistModel.card(from: 1, moving: .down, in: cards) == 3)
        #expect(SnapAssistModel.card(from: 3, moving: .down, in: cards) == 4)
        #expect(SnapAssistModel.card(from: 1, moving: .right, in: cards) == 1)
        #expect(SnapAssistModel.card(from: 0, moving: .up, in: cards) == 0)
        #expect(SnapAssistModel.card(from: nil, moving: .left, in: []) == nil)
    }

    @Test("The picked window goes against the edge across from the snapped one")
    func opposite() {
        #expect(SnapAssistModel.opposite(of: .left) == .right)
        #expect(SnapAssistModel.opposite(of: .bottom) == .top)
    }
}
