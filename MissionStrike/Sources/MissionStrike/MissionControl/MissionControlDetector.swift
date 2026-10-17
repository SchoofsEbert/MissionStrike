import AppKit
import CoreGraphics

/// Checks whether Mission Control is currently active by inspecting system overlay windows.
///
/// Detection requires multiple large, opaque overlays (to reject dock-bounce false positives)
/// and at least one Dock-owned overlay among them. On macOS 27+, Mission Control's second
/// full-screen surface is owned by WindowManager rather than Dock; companion overlays from
/// config cover that case while older Dock-only sessions keep working unchanged.
///
/// Reads only the window list, no Accessibility, so it is cheap enough for the event tap.
struct MissionControlDetector: Sendable {
    var config: MissionStrikeConfig = .default

    /// Live check using system APIs (CGWindowList + NSScreen).
    func isActive() -> Bool {
        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let screenSizes = NSScreen.screens.map { $0.frame.size }
        return Self.isActive(windowList: windowList, screenSizes: screenSizes, config: config)
    }

    /// Pure, testable detection logic with no system dependencies.
    /// Pass in window list data and screen sizes to verify heuristics.
    static func isActive(
        windowList: [[String: Any]],
        screenSizes: [CGSize],
        config: MissionStrikeConfig = .default
    ) -> Bool {
        let fraction = config.minimumScreenCoverageFraction
        let thresholds: [(minWidth: CGFloat, minHeight: CGFloat)]

        if screenSizes.isEmpty {
            let fallback = config.fallbackScreenSize
            thresholds = [(fallback.width * fraction, fallback.height * fraction)]
        } else {
            thresholds = screenSizes.map { size in
                (size.width * fraction, size.height * fraction)
            }
        }

        var dockQualifyingCount = 0
        var totalQualifyingCount = 0

        for info in windowList {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0

            let isDockOverlay = owner == "Dock"
                && config.missionControlOverlayLayers.contains(layer)
            let isCompanionOverlay = config.missionControlCompanionOverlays[owner]?.contains(layer) == true
            guard isDockOverlay || isCompanionOverlay else { continue }

            // Filter out transparent hit-test overlays (e.g. dock auto-show, app bounce)
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha >= config.minimumOverlayAlpha else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let coversAScreen = thresholds.contains { threshold in
                bounds.width > threshold.minWidth && bounds.height > threshold.minHeight
            }
            guard coversAScreen else { continue }

            totalQualifyingCount += 1
            if isDockOverlay {
                dockQualifyingCount += 1
            }

            // Require a Dock overlay so companion-only stacks cannot false-trigger,
            // while still needing enough total overlays to reject a lone dock bounce.
            if dockQualifyingCount >= 1,
               totalQualifyingCount >= config.minimumOverlayCount {
                return true
            }
        }
        return false
    }
}
