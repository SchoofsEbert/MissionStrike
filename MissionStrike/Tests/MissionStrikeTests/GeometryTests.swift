@testable import MissionStrike
import CoreGraphics
import Testing

@Suite("Screen Coordinates")
struct ScreenCoordinatesTests {
    private let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let leftOfPrimary = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
    private let abovePrimary = CGRect(x: 0, y: 1117, width: 1920, height: 1080)

    @Test("The primary display is the one at the origin, wherever it is listed")
    func primaryHeight() {
        #expect(ScreenCoordinates.mainDisplayHeight(screenFrames: [leftOfPrimary, primary]) == 1117)
        #expect(ScreenCoordinates.mainDisplayHeight(screenFrames: [primary, abovePrimary]) == 1117)
    }

    @Test("Without a screen at the origin the first one counts; no screens means no flip")
    func noPrimary() {
        #expect(ScreenCoordinates.mainDisplayHeight(screenFrames: [leftOfPrimary, abovePrimary]) == 1440)
        #expect(ScreenCoordinates.mainDisplayHeight(screenFrames: []) == 0)
        #expect(ScreenCoordinates.yFlipped(CGPoint(x: 5, y: 7), mainDisplayHeight: 0) == CGPoint(x: 5, y: 7))
    }

    @Test("Points on any screen flip against the primary display's height")
    func flipPoints() {
        #expect(ScreenCoordinates.yFlipped(CGPoint(x: 10, y: 1117), mainDisplayHeight: 1117) == CGPoint(x: 10, y: 0))
        // A screen above the primary has negative AX y.
        #expect(ScreenCoordinates.yFlipped(CGPoint(x: 10, y: 1500), mainDisplayHeight: 1117) == CGPoint(x: 10, y: -383))
        // A screen left of and lower than the primary.
        #expect(ScreenCoordinates.yFlipped(CGPoint(x: -100, y: -150), mainDisplayHeight: 1117) == CGPoint(x: -100, y: 1267))
    }

    @Test("Rects flip by their far edge and flip back unchanged")
    func flipRects() {
        let rect = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
        let flipped = ScreenCoordinates.yFlipped(rect, mainDisplayHeight: 1117)
        #expect(flipped == CGRect(x: -2560, y: -123, width: 2560, height: 1440))
        #expect(ScreenCoordinates.yFlipped(flipped, mainDisplayHeight: 1117) == rect)
    }
}

@MainActor
@Suite("Hover Badge")
struct HoverBadgeTests {

    @Test("The badge's circle sits just inside the thumbnail's top-left corner")
    func badgeFrame() {
        let thumbnail = CGRect(x: 100, y: 200, width: 400, height: 300)
        let size = CGSize(width: 30, height: 30)
        let frame = HoverBadgeController.badgeFrame(size: size, on: thumbnail)
        let circleCentre = HoverBadgeView.padding + HoverBadgeView.diameter / 2
        // AppKit space: the top edge is maxY.
        #expect(frame.minX + circleCentre == thumbnail.minX + 10)
        #expect(frame.maxY - circleCentre == thumbnail.maxY - 10)
        #expect(frame.size == size)
    }

    @Test("A wider badge (with a label) grows to the right, keeping the circle in place")
    func wideBadge() {
        let thumbnail = CGRect(x: 100, y: 200, width: 400, height: 300)
        let narrow = HoverBadgeController.badgeFrame(size: CGSize(width: 30, height: 30), on: thumbnail)
        let wide = HoverBadgeController.badgeFrame(size: CGSize(width: 70, height: 30), on: thumbnail)
        #expect(narrow.origin == wide.origin)
    }
}

@Suite("Dock Snapshot")
struct DockSnapshotTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let shownList = CGRect(x: 659, y: 1040, width: 410, height: 69)
    private let safari = CGRect(x: 670, y: 1045, width: 56, height: 56)

    @Test("On a running app's icon, near the Dock, or elsewhere")
    func verdicts() {
        let snapshot = DockSnapshot(listFrames: [shownList], runningAppIcons: [safari])
        #expect(snapshot.verdict(at: [CGPoint(x: 690, y: 1070)]) == .runningApp)
        #expect(snapshot.verdict(at: [CGPoint(x: 900, y: 1070)]) == .maybe)
        #expect(snapshot.verdict(at: [CGPoint(x: 900, y: 1035)]) == .maybe)
        #expect(snapshot.verdict(at: [CGPoint(x: 900, y: 500)]) == .elsewhere)
    }

    @Test("Any candidate point may hit")
    func candidates() {
        let snapshot = DockSnapshot(listFrames: [shownList], runningAppIcons: [safari])
        #expect(snapshot.verdict(at: [CGPoint(x: 900, y: 500), CGPoint(x: 690, y: 1070)]) == .runningApp)
    }

    @Test("With magnification, icons move, so no icon is trusted")
    func magnification() {
        let snapshot = DockSnapshot(listFrames: [shownList], runningAppIcons: [safari], magnification: 64)
        #expect(snapshot.verdict(at: [CGPoint(x: 690, y: 1070)]) == .maybe)
        #expect(snapshot.verdict(at: [CGPoint(x: 690, y: 990)]) == .maybe)
    }

    @Test("An auto-hidden Dock sits off screen")
    func hidden() {
        let hidden = DockSnapshot(listFrames: [CGRect(x: 659, y: 1117, width: 410, height: 69)], runningAppIcons: [])
        #expect(!hidden.isShown(on: [screen]))
        #expect(DockSnapshot(listFrames: [shownList], runningAppIcons: []).isShown(on: [screen]))
        #expect(!DockSnapshot(listFrames: [], runningAppIcons: []).isShown(on: [screen]))
    }
}
