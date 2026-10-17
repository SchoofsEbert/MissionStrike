@testable import MissionStrike
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite("Overlays")
struct OverlayTests {

    // MARK: - Canvas

    @Test("Canvas coordinates start at the screen's top-left corner")
    func canvasCoordinates() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(OverlayCanvas.local(CGRect(x: 100, y: 700, width: 300, height: 150), in: main)
            == CGRect(x: 100, y: 50, width: 300, height: 150))
        // A second screen to the right and a little higher.
        let side = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
        #expect(OverlayCanvas.local(CGRect(x: 1540, y: 1180, width: 200, height: 100), in: side)
            == CGRect(x: 100, y: 0, width: 200, height: 100))
    }

    // MARK: - Thumbnails

    @Test("Scanning finds every thumbnail and Space, and skips thumbnails' subtrees")
    func thumbnailScan() {
        let root = FakeElement(role: "AXApplication")
        let group = root.add(FakeElement(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        let first = group.add(FakeElement(role: "AXButton", frame: CGRect(x: 100, y: 200, width: 300, height: 200), wid: 42))
        first.add(FakeElement(role: "AXButton", frame: CGRect(x: 120, y: 220, width: 50, height: 50), wid: 99))
        group.add(FakeElement(role: "AXButton", frame: CGRect(x: 500, y: 200, width: 300, height: 200), wid: 43))
        group.add(FakeElement(role: "AXButton", wid: 44))
        let bar = root.add(FakeElement(role: "AXGroup", title: "Spaces Bar", frame: CGRect(x: 0, y: 0, width: 1000, height: 80)))
        bar.add(FakeElement(role: "AXButton", frame: CGRect(x: 100, y: 20, width: 160, height: 60),
                            actions: ["AXRemoveDesktop", "AXPress"]))

        let found = MissionControlThumbnails.elements(in: root, includeSpaces: true)
        #expect(found.thumbnails.map(\.windowID) == [42, 43])
        #expect(found.thumbnails.first?.frame == CGRect(x: 100, y: 200, width: 300, height: 200))
        #expect(found.spaces.count == 1)
        #expect(found.spaces.first?.canOpen == true)
        #expect(MissionControlThumbnails.elements(in: root, includeSpaces: false).spaces.isEmpty)
    }

    @Test("The window list maps window IDs to app windows, leaving out the system's")
    func appWindows() {
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: CGWindowID(42), kCGWindowOwnerName as String: "Notes", kCGWindowOwnerPID as String: Int32(7)],
            [kCGWindowNumber as String: CGWindowID(43), kCGWindowOwnerName as String: "Dock", kCGWindowOwnerPID as String: Int32(9)],
            [kCGWindowNumber as String: CGWindowID(44), kCGWindowOwnerName as String: "Mail", kCGWindowOwnerPID as String: Int32(0)]
        ]
        #expect(WindowList.appWindows(in: list) == [42: AppWindow(pid: 7, ownerName: "Notes", windowID: 42)])
    }
}
