@testable import Vantage
import CoreGraphics
import Testing

@Suite("Tab Swipe")
struct TabSwipeTests {
    private var recognizer = TabSwipeRecognizer()

    /// Three fingers side by side, centred on `x`, `y`.
    private func fingers(_ x: CGFloat, _ y: CGFloat = 0.5, count: Int = 3) -> [CGPoint] {
        (0..<count).map { CGPoint(x: x + CGFloat($0) * 0.05, y: y) }
    }

    /// Feeds positions in order and collects the steps.
    private mutating func steps(_ frames: [[CGPoint]]) -> [TabSwipeRecognizer.Step] {
        frames.compactMap { recognizer.update(touching: $0) }
    }

    @Test("A swipe right past the first step goes to the next tab once")
    mutating func swipeRight() {
        #expect(steps([fingers(0.3), fingers(0.33), fingers(0.37), fingers(0.4)]) == [.next])
    }

    @Test("A swipe left goes to the previous tab")
    mutating func swipeLeft() {
        #expect(steps([fingers(0.5), fingers(0.43)]) == [.previous])
    }

    @Test("Resting fingers or a short nudge switch nothing")
    mutating func shortTravel() {
        #expect(steps([fingers(0.3), fingers(0.3), fingers(0.32), fingers(0.34)]).isEmpty)
    }

    @Test("A longer swipe goes one tab further per repeat step, and back again")
    mutating func longSwipe() {
        let frames = [0.2, 0.27, 0.33, 0.4, 0.45, 0.53, 0.4].map { fingers($0) }
        #expect(steps(frames) == [.next, .next, .next, .previous])
    }

    @Test("A vertical swipe is Mission Control's, even when it turns sideways")
    mutating func verticalSwipe() {
        #expect(steps([fingers(0.4, 0.3), fingers(0.41, 0.4), fingers(0.6, 0.4)]).isEmpty)
    }

    @Test("Once switching, vertical drift doesn't stop the swipe")
    mutating func driftAfterStep() {
        #expect(steps([fingers(0.3, 0.3), fingers(0.37, 0.32), fingers(0.45, 0.45), fingers(0.58, 0.5)]) == [.next, .next])
    }

    @Test("Two or four fingers switch nothing, and lifting the fourth doesn't start a swipe")
    mutating func otherFingerCounts() {
        #expect(steps([fingers(0.3, count: 2), fingers(0.5, count: 2)]).isEmpty)
        #expect(steps([fingers(0.3, count: 4), fingers(0.3), fingers(0.5)]).isEmpty)
    }

    @Test("Lifting the fingers starts over from where they land next")
    mutating func liftAndLand() {
        #expect(steps([fingers(0.3), fingers(0.34), []]).isEmpty)
        #expect(steps([fingers(0.6), fingers(0.63)]).isEmpty)
        #expect(steps([fingers(0.67)]) == [.next])
    }

    @Test("Each of macOS's own three-finger gestures is reported")
    func conflicts() {
        #expect(TabSwipeConflict.conflicts(horizontalSwipe: 0, threeFingerDrag: false).isEmpty)
        #expect(TabSwipeConflict.conflicts(horizontalSwipe: 1, threeFingerDrag: false) == [.swipeBetweenPages])
        #expect(TabSwipeConflict.conflicts(horizontalSwipe: 2, threeFingerDrag: true) == [.swipeBetweenFullScreenApps, .threeFingerDrag])
    }
}

@Suite("Tab Swipe Apps")
struct TabSwipeAppsTests {
    private let listed: Set<String> = ["com.google.Chrome"]

    @Test("All Apps allows every app, also one without a bundle ID")
    func allApps() {
        let apps = TabSwipeApps(scope: .allApps, bundleIDs: listed)
        #expect(apps.allows("com.apple.Terminal"))
        #expect(apps.allows(nil))
    }

    @Test("Only These Apps allows just the listed ones")
    func onlyListed() {
        let apps = TabSwipeApps(scope: .onlyListed, bundleIDs: listed)
        #expect(apps.allows("com.google.Chrome"))
        #expect(!apps.allows("com.apple.Terminal"))
        #expect(!apps.allows(nil))
    }

    @Test("All Apps Except These leaves the listed ones alone")
    func allExceptListed() {
        let apps = TabSwipeApps(scope: .allExceptListed, bundleIDs: listed)
        #expect(!apps.allows("com.google.Chrome"))
        #expect(apps.allows("com.apple.Terminal"))
        #expect(apps.allows(nil))
    }
}
