import AppKit
import CoreGraphics

/// Y-flip between AppKit/Quartz-style click coordinates and Accessibility space.
///
/// - Quartz / typical `NSEvent.mouseLocation` in Mission Control: visual top → **high** Y.
/// - AX frames / `AXUIElementCopyElementAtPosition`: origin top-left → visual top → **low** Y.
///
/// Use only when the hit tester decides Mission Control needs it (macOS 27+ / `wid` UI).
enum ScreenCoordinates {
    static var mainDisplayHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    static func yFlipped(_ point: CGPoint) -> CGPoint {
        let h = mainDisplayHeight
        guard h > 0 else { return point }
        return CGPoint(x: point.x, y: h - point.y)
    }
}
