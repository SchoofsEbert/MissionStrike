import AppKit
import ImageIO
import ScreenCaptureKit

/// The wallpaper behind the free part of the screen, which the picker draws its windows on,
/// as Mission Control does. Taken fresh for each picker and dropped with it: nothing is kept
/// between pickers.
enum SnapBackdrop {
    /// What to show; all rects in AX space (top-left origin), points.
    struct Request: Sendable {
        let region: CGRect
        let screen: CGRect
        let scale: CGFloat
        let fileURL: URL?
        /// The wallpaper fills the screen, cropped as needed, which is macOS's default. Other
        /// placements (fit, centre, stretch) aren't drawn from the file.
        let fillsScreen: Bool
    }

    /// Reads what only the main thread should: the screen's wallpaper file and how it's placed.
    @MainActor
    static func request(region: CGRect, on screen: NSScreen) -> Request {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue
        return Request(
            region: region,
            screen: ScreenCoordinates.yFlipped(screen.frame),
            scale: screen.backingScaleFactor,
            fileURL: NSWorkspace.shared.desktopImageURL(for: screen),
            fillsScreen: (scaling ?? .scaleProportionallyUpOrDown) == .scaleProportionallyUpOrDown && clipping ?? true
        )
    }

    /// How to capture the wallpaper window as it shows, from content ScreenCaptureKit listed
    /// with desktop windows: exact for every kind of wallpaper. Only the region is captured.
    static func captureSetup(
        _ request: Request,
        from content: SCShareableContent
    ) -> (filter: SCContentFilter, configuration: SCStreamConfiguration)? {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let center = CGPoint(x: request.region.midX, y: request.region.midY)
        // The wallpaper is the topmost window at desktop level; below it each display has a
        // black backstop, which belongs to no app.
        guard let wallpaper = content.windows
            .filter({ $0.windowLayer <= desktopLevel && $0.owningApplication != nil && $0.frame.contains(center) })
            .max(by: { $0.windowLayer < $1.windowLayer }) else {
            return nil
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = request.region.offsetBy(dx: -wallpaper.frame.minX, dy: -wallpaper.frame.minY)
        configuration.width = Int(request.region.width * request.scale)
        configuration.height = Int(request.region.height * request.scale)
        configuration.showsCursor = false
        return (SCContentFilter(desktopIndependentWindow: wallpaper), configuration)
    }

    /// The region cut from the wallpaper file, without Screen Recording. Nil for dynamic
    /// wallpapers, whose file holds several pictures without saying which one shows, and for
    /// placements other than filling the screen.
    static func decode(_ request: Request) -> CGImage? {
        guard request.fillsScreen, let url = request.fileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        let target = CGSize(width: request.screen.width * request.scale, height: request.screen.height * request.scale)
        let fill = max(target.width / width, target.height / height)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * fill).rounded(.up))
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // Filling crops the overflow evenly on both sides.
        let local = request.region.offsetBy(dx: -request.screen.minX, dy: -request.screen.minY)
        let crop = CGRect(
            x: (CGFloat(image.width) - target.width) / 2 + local.minX * request.scale,
            y: (CGFloat(image.height) - target.height) / 2 + local.minY * request.scale,
            width: local.width * request.scale,
            height: local.height * request.scale
        ).integral
        return image.cropping(to: crop)
    }
}
