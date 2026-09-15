import AppKit
import CoreGraphics

/// Converts between Quartz (CGEvent) and Cocoa / CGWindowList screen spaces.
///
/// `CGEvent.location` uses a lower-left origin on the main display.
/// Accessibility hit-testing and `CGWindowListCopyWindowInfo` bounds use an
/// upper-left origin on the main display.
enum ScreenCoordinates {
    /// Converts a Quartz / CGEvent point into Cocoa / Accessibility coordinates.
    static func cocoaPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        guard mainHeight > 0 else { return point }
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }
}
