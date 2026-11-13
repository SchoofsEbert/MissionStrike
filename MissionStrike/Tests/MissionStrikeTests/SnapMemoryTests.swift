@testable import MissionStrike
import CoreGraphics
import Testing

@Suite("Snap Memory")
struct SnapMemoryTests {
    private let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let free = CGRect(x: 300, y: 200, width: 500, height: 400)
    /// Every window the tests use still exists.
    private let live: () -> Set<CGWindowID> = { Set(1...CGWindowID(SnapMemory.capacity)) }

    private func snapped(_ memory: inout SnapMemory, _ id: CGWindowID, _ action: SnapAction, step: Int?, from frame: CGRect) -> CGRect {
        let taken = step.map { SnapLayout.frame(for: action, step: $0, in: area) } ?? area
        memory.willMove(id, from: frame, liveWindows: live)
        memory.didMove(id, SnapRecord(action: action, step: step, windowID: id, frame: taken), liveWindows: live)
        return taken
    }

    @Test("Snapped again and again, a window restores to where it was before the first snap")
    func restoresToFirstFrame() {
        var memory = SnapMemory()
        let half = snapped(&memory, 1, .left, step: 0, from: free)
        let third = snapped(&memory, 1, .left, step: 1, from: half)
        #expect(memory.takeRestore(1, current: third, areas: [area]) == free)
        #expect(memory.takeRestore(1, current: free, areas: [area]) == nil)
    }

    @Test("Moved by hand after a snap, a window restores to where it was moved")
    func movedByHand() {
        var memory = SnapMemory()
        _ = snapped(&memory, 1, .left, step: 0, from: free)
        let byHand = CGRect(x: 600, y: 300, width: 400, height: 300)
        _ = snapped(&memory, 1, .right, step: 0, from: byHand)
        #expect(memory.takeRestore(1, current: .zero, areas: [area]) == byHand)
    }

    @Test("Filling a window that fills its screen restores it, even when it couldn't fill exactly")
    func fillToggles() {
        var memory = SnapMemory()
        _ = snapped(&memory, 1, .maximize, step: 0, from: free)
        #expect(memory.fillRestores(1, current: area, areas: [area]))
        // Terminal rounds to whole characters.
        var rounded = SnapMemory()
        rounded.willMove(2, from: free, liveWindows: live)
        let short = CGRect(x: 0, y: 25, width: 1440, height: 868)
        rounded.didMove(2, SnapRecord(action: .maximize, step: 0, windowID: 2, frame: short), liveWindows: live)
        #expect(rounded.fillRestores(2, current: short, areas: [area]))
        #expect(!SnapMemory().fillRestores(3, current: area, areas: [area]))
    }

    @Test("A window whose screen is gone restores to the middle of the one it's on, as far as it fits")
    func goneScreen() {
        var memory = SnapMemory()
        let onExternal = CGRect(x: 2000, y: 100, width: 1600, height: 900)
        _ = snapped(&memory, 1, .left, step: 0, from: onExternal)
        let restored = memory.takeRestore(1, current: SnapLayout.frame(for: .left, step: 0, in: area), areas: [area])
        #expect(restored == CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    @Test("A display move keeps the Restore frame for the next snap")
    func displayMove() {
        var memory = SnapMemory()
        let half = snapped(&memory, 1, .left, step: 0, from: free)
        let moved = half.offsetBy(dx: 1440, dy: 0)
        memory.willMove(1, from: half, liveWindows: live)
        memory.didMove(1, SnapRecord(action: .nextDisplay, step: nil, windowID: 1, frame: moved), liveWindows: live)
        _ = snapped(&memory, 1, .left, step: 0, from: moved)
        #expect(memory.takeRestore(1, current: .zero, areas: [area]) == free)
    }

    @Test("At capacity, windows that are gone are forgotten first, then the least recently snapped")
    func capacity() {
        var memory = SnapMemory()
        for id in 1...CGWindowID(SnapMemory.capacity) {
            _ = snapped(&memory, id, .left, step: 0, from: free)
        }
        #expect(memory.restoreFrames.count == SnapMemory.capacity)
        // Snapping a known window again makes no room.
        _ = snapped(&memory, 1, .left, step: 0, from: free)
        #expect(memory.restoreFrames.count == SnapMemory.capacity)

        var pruned = memory
        pruned.willMove(999, from: free, liveWindows: { [1, 2] })
        #expect(pruned.restoreFrames.keys.sorted() == [1, 2, 999])

        // All still open: the least recently snapped (window 2, as 1 was snapped again) goes.
        memory.willMove(999, from: free, liveWindows: live)
        #expect(memory.restoreFrames.count == SnapMemory.capacity)
        #expect(memory.restoreFrames[2] == nil)
        #expect(memory.restoreFrames[1] == free)
    }
}
