@testable import Vantage
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("Snap Backdrop")
struct SnapBackdropTests {
    /// A picture, red on the left half and blue on the right, saved with `frames` copies.
    private func wallpaper(frames: Int = 1, width: Int = 400, height: Int = 200, orientation: Int = 1) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func request(_ url: URL?, region: CGRect, fillsScreen: Bool = true) -> SnapBackdrop.Request {
        SnapBackdrop.Request(
            region: region,
            screen: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1,
            fileURL: url,
            fillsScreen: fillsScreen
        )
    }

    /// The red and blue of the pixel at a point.
    private func color(of image: CGImage, at point: CGPoint) throws -> (red: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let flippedY = CGFloat(image.height) - 1 - point.y
        context.draw(image, in: CGRect(x: -point.x, y: -flippedY, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (pixel[0], pixel[2])
    }

    @Test("Cuts the region from the wallpaper as it fills the screen, cropped evenly")
    func cropsFilledWallpaper() throws {
        let url = try wallpaper()
        defer { try? FileManager.default.removeItem(at: url) }
        // A square screen shows the middle of the 2:1 picture: red on its left, blue on its right.
        let left = try #require(SnapBackdrop.decode(request(url, region: CGRect(x: 0, y: 0, width: 40, height: 100))))
        #expect(left.width == 40 && left.height == 100)
        #expect(try color(of: left, at: CGPoint(x: 20, y: 50)).red > 200)
        let right = try #require(SnapBackdrop.decode(request(url, region: CGRect(x: 60, y: 0, width: 40, height: 100))))
        #expect(try color(of: right, at: CGPoint(x: 20, y: 50)).blue > 200)
    }

    @Test("A wallpaper smaller than the screen is enlarged to fill it, not offset")
    func enlargesSmallWallpaper() throws {
        // 40×20 on a 100×100 screen: shown 200×100, so the screen sees its middle half.
        let url = try wallpaper(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try #require(SnapBackdrop.decode(request(url, region: CGRect(x: 0, y: 0, width: 100, height: 100))))
        #expect(whole.width == 100 && whole.height == 100)
        #expect(try color(of: whole, at: CGPoint(x: 10, y: 50)).red > 200)
        #expect(try color(of: whole, at: CGPoint(x: 90, y: 50)).blue > 200)
    }

    @Test("A photo stored on its side is turned upright before it's cut")
    func uprightsRotatedPhoto() throws {
        // Stored 200×400, red left and blue right, marked as turned a quarter (orientation 6).
        let url = try wallpaper(width: 200, height: 400, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(SnapBackdrop.decode(request(url, region: CGRect(x: 0, y: 0, width: 100, height: 100))))
        #expect(image.width == 100 && image.height == 100)
        // Upright, the halves run top and bottom: the screen shows the middle, both colours.
        let top = try color(of: image, at: CGPoint(x: 50, y: 10))
        let bottom = try color(of: image, at: CGPoint(x: 50, y: 90))
        #expect((top.red > 200) != (bottom.red > 200))
    }

    @Test("Dynamic wallpapers and other placements aren't drawn from the file")
    func refuses() throws {
        let dynamic = try wallpaper(frames: 2)
        defer { try? FileManager.default.removeItem(at: dynamic) }
        #expect(SnapBackdrop.decode(request(dynamic, region: CGRect(x: 0, y: 0, width: 50, height: 100))) == nil)
        let still = try wallpaper()
        defer { try? FileManager.default.removeItem(at: still) }
        #expect(SnapBackdrop.decode(request(still, region: CGRect(x: 0, y: 0, width: 50, height: 100), fillsScreen: false)) == nil)
        #expect(SnapBackdrop.decode(request(nil, region: CGRect(x: 0, y: 0, width: 50, height: 100))) == nil)
    }
}
