import AppKit
import CoreGraphics

/// Y-flip between AppKit/Quartz-style click coordinates and Accessibility space.
///
/// - Quartz / typical `NSEvent.mouseLocation` in Mission Control: visual top → **high** Y.
/// - AX frames / `AXUIElementCopyElementAtPosition`: origin top-left → visual top → **low** Y.
///
/// Both spaces are anchored to the primary display, so every screen flips by its height.
/// Use only when the hit tester decides Mission Control needs it (macOS 27+ / `wid` UI).
enum ScreenCoordinates {
    static var mainDisplayHeight: CGFloat {
        mainDisplayHeight(screenFrames: NSScreen.screens.map(\.frame))
    }

    /// The primary display sits at the origin; AppKit also lists it first.
    static func mainDisplayHeight(screenFrames: [CGRect]) -> CGFloat {
        (screenFrames.first { $0.origin == .zero } ?? screenFrames.first)?.height ?? 0
    }

    /// Every screen's frame in AX (top-left origin) space.
    static var axScreenFrames: [CGRect] {
        let height = mainDisplayHeight
        return NSScreen.screens.map { yFlipped($0.frame, mainDisplayHeight: height) }
    }

    static func yFlipped(_ point: CGPoint) -> CGPoint {
        yFlipped(point, mainDisplayHeight: mainDisplayHeight)
    }

    static func yFlipped(_ point: CGPoint, mainDisplayHeight height: CGFloat) -> CGPoint {
        guard height > 0 else { return point }
        return CGPoint(x: point.x, y: height - point.y)
    }

    /// Flips a rect between AX (top-left origin) and AppKit (bottom-left origin) space.
    static func yFlipped(_ rect: CGRect) -> CGRect {
        yFlipped(rect, mainDisplayHeight: mainDisplayHeight)
    }

    static func yFlipped(_ rect: CGRect, mainDisplayHeight height: CGFloat) -> CGRect {
        guard height > 0 else { return rect }
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
