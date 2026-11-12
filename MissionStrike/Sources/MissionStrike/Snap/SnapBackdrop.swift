import AppKit
import ImageIO
import ScreenCaptureKit

/// The wallpaper behind the free part of the screen, which the picker draws its windows on,
/// as Mission Control does. Taken fresh for each picker and dropped with it: nothing is kept
/// between pickers.
enum SnapBackdrop {
    private static let wallpaperOwners: Set<String> = ["com.apple.WindowManager", "com.apple.dock"]

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
        // A window that covers the display at desktop level, below each display's black
        // backstop's owner-less window. macOS 27 draws the wallpaper in WindowManager (the Dock
        // did before); a desktop-level window of another app, such as a widget tool, isn't it.
        let covering = content.windows.filter {
            $0.windowLayer <= desktopLevel && $0.owningApplication != nil && $0.frame.contains(center)
                && $0.frame.width >= request.screen.width - 1 && $0.frame.height >= request.screen.height - 1
        }
        let system = covering.filter { Self.wallpaperOwners.contains($0.owningApplication?.bundleIdentifier ?? "") }
        guard let wallpaper = (system.isEmpty ? covering : system).max(by: { $0.windowLayer < $1.windowLayer }) else {
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
        // The picture as shown, turned upright: phone photos are stored on their side.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let upright = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let target = CGSize(width: request.screen.width * request.scale, height: request.screen.height * request.scale)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * Self.fillScale(upright, into: target)).rounded(.up))
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // ImageIO never enlarges: work from the size it gave. Filling crops the overflow evenly.
        let fill = Self.fillScale(CGSize(width: image.width, height: image.height), into: target)
        let overflow = CGSize(width: CGFloat(image.width) * fill - target.width, height: CGFloat(image.height) * fill - target.height)
        let local = request.region.offsetBy(dx: -request.screen.minX, dy: -request.screen.minY)
        let output = CGSize(width: (local.width * request.scale).rounded(), height: (local.height * request.scale).rounded())
        let crop = CGRect(
            x: (overflow.width / 2 + local.minX * request.scale) / fill,
            y: (overflow.height / 2 + local.minY * request.scale) / fill,
            width: output.width / fill,
            height: output.height / fill
        ).integral
        // Drawn into a picture of its own, so the whole decoded wallpaper can go.
        guard let cropped = image.cropping(to: crop), output.width >= 1, output.height >= 1,
              let context = CGContext(
                  data: nil, width: Int(output.width), height: Int(output.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(origin: .zero, size: output))
        return context.makeImage()
    }

    /// How much a picture is scaled to fill a screen, cropping what sticks out.
    private static func fillScale(_ size: CGSize, into target: CGSize) -> CGFloat {
        max(target.width / size.width, target.height / size.height)
    }
}
