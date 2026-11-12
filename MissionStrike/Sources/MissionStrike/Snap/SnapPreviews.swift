import CoreGraphics
import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "Snap")

/// Pictures of windows for Snap Assist, with ScreenCaptureKit. Needs Screen Recording access;
/// without it, Snap Assist shows icons.
enum SnapPreviews {
    /// Long side of a picture, in pixels: sharp in a cell on a Retina screen, and quick to take.
    static let maxPixels: CGFloat = 840

    static var isAllowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Pictures of these windows, taken at once; windows that can't be captured are left out.
    static func capture(_ windowIDs: [CGWindowID]) async -> [CGWindowID: CGImage] {
        let signpost = performanceSignposter.beginInterval("Snap previews")
        defer { performanceSignposter.endInterval("Snap previews", signpost) }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            logger.info("Snap previews: no shareable content (\(error.localizedDescription, privacy: .public)).")
            return [:]
        }
        let wanted = Set(windowIDs)
        let windows = content.windows.filter { wanted.contains($0.windowID) }
        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                let request = CaptureRequest(
                    filter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: configuration(for: window.frame.size)
                )
                let windowID = window.windowID
                group.addTask {
                    let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: request.filter,
                        configuration: request.configuration
                    )
                    return (windowID, image)
                }
            }
            var images: [CGWindowID: CGImage] = [:]
            for await (windowID, image) in group {
                images[windowID] = image
            }
            return images
        }
    }

    /// Made here and only read by the capture: never shared while it changes.
    private struct CaptureRequest: @unchecked Sendable {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    private static func configuration(for size: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(1, maxPixels / max(size.width * 2, size.height * 2, 1)) * 2
        configuration.width = max(1, Int(size.width * scale))
        configuration.height = max(1, Int(size.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }
}
