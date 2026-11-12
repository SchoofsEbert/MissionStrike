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

    /// Pictures of these windows and, with a request, of the wallpaper behind the picker, all
    /// taken at once from one listing; windows that can't be captured are left out.
    static func capture(
        _ windowIDs: [CGWindowID],
        backdrop: SnapBackdrop.Request?
    ) async -> (previews: [CGWindowID: CGImage], backdrop: CGImage?) {
        let signpost = performanceSignposter.beginInterval("Snap previews")
        defer { performanceSignposter.endInterval("Snap previews", signpost) }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(backdrop == nil, onScreenWindowsOnly: true)
        } catch {
            logger.info("Snap previews: no shareable content (\(error.localizedDescription, privacy: .public)).")
            return ([:], nil)
        }
        guard !Task.isCancelled else { return ([:], nil) }

        // Every capture is set up here, from the listing, then all run at once.
        let wanted = Set(windowIDs)
        var requests: [(windowID: CGWindowID?, request: CaptureRequest)] = content.windows
            .filter { wanted.contains($0.windowID) }
            .map { window in
                (window.windowID, CaptureRequest(
                    filter: SCContentFilter(desktopIndependentWindow: window),
                    configuration: configuration(for: window.frame.size)
                ))
            }
        if let backdrop, let wallpaper = SnapBackdrop.captureSetup(backdrop, from: content) {
            requests.append((nil, CaptureRequest(filter: wallpaper.filter, configuration: wallpaper.configuration)))
        }
        return await withTaskGroup(of: (CGWindowID?, CGImage?).self) { group in
            for (windowID, request) in requests {
                group.addTask {
                    let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: request.filter,
                        configuration: request.configuration
                    )
                    return (windowID, image)
                }
            }
            var previews: [CGWindowID: CGImage] = [:]
            var wallpaper: CGImage?
            for await (windowID, image) in group {
                if let windowID {
                    previews[windowID] = image
                } else {
                    wallpaper = image
                }
            }
            return (previews, wallpaper)
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
