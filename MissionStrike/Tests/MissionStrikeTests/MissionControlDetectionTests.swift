@testable import MissionStrike
import CoreGraphics
import Testing

// MARK: - Test Helpers

/// Builds a mock CGWindowList entry matching the shape returned by CGWindowListCopyWindowInfo.
private func mockWindowEntry(
    owner: String,
    layer: Int,
    bounds: CGRect,
    alpha: CGFloat = 1.0
) -> [String: Any] {
    [
        kCGWindowOwnerName as String: owner,
        kCGWindowLayer as String: layer,
        kCGWindowBounds as String: [
            "X": bounds.origin.x,
            "Y": bounds.origin.y,
            "Width": bounds.width,
            "Height": bounds.height
        ],
        kCGWindowAlpha as String: alpha
    ]
}

/// Helper: two full-screen Dock overlays that represent a real Mission Control session.
private func missionControlWindows(
    screen: CGSize = CGSize(width: 1920, height: 1080)
) -> [[String: Any]] {
    [
        mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(origin: .zero, size: screen)),
        mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(origin: .zero, size: screen))
    ]
}

private let standardScreen = CGSize(width: 1920, height: 1080)
private let smallScreen = CGSize(width: 1280, height: 800)

// MARK: - Detection Heuristic Tests

@Suite("Mission Control Detection")
struct MissionControlDetectionTests {

    // MARK: - Positive detection

    @Test("Dock overlays at layers 18+20 covering full screen are detected")
    func dockOverlayBothLayers() {
        let windowList = missionControlWindows()
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Two Dock overlays on same layer are detected")
    func twoDockOverlaysSameLayer() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    // MARK: - Negative detection

    @Test("Single Dock overlay is not enough (dock bounce false positive)")
    func singleDockOverlayNotDetected() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Dock bounce with transparent overlay is not detected")
    func dockBounceTransparentOverlay() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 0.0),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 0.0)
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Dock overlay that is too small for any screen is not detected")
    func dockOverlayTooSmall() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 200, height: 50)),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 200, height: 50))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Non-Dock window at Mission Control layer is not detected")
    func nonDockOwnerIgnored() {
        let windowList = [
            mockWindowEntry(owner: "SomeOtherApp", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            mockWindowEntry(owner: "SomeOtherApp", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Dock window at non-Mission-Control layer is not detected")
    func dockWrongLayer() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            mockWindowEntry(owner: "Dock", layer: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Empty window list returns false")
    func emptyWindowList() {
        #expect(!MissionControlActiveChecker.isActive(
            windowList: [],
            screenSizes: [standardScreen]
        ))
    }

    // MARK: - Multi-display

    @Test("Overlay covering secondary screen but not primary is detected")
    func multiDisplaySecondaryScreenCovered() {
        // Overlays are 1280x800 -- too small for the 1920x1080 primary,
        // but covers the 1280x800 secondary.
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen, smallScreen]
        ))
    }

    @Test("Overlay too small for ALL screens is not detected on multi-display")
    func multiDisplayTooSmallForAll() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 400, height: 300)),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen, smallScreen]
        ))
    }

    // MARK: - Fallback screen size

    @Test("Empty screen list uses fallback dimensions")
    func fallbackScreenSize() {
        // Overlay covers default fallback (1920x1080 x 0.5 = 960x540)
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: []
        ))
    }

    // MARK: - Custom config

    @Test("Custom overlay layers are respected")
    func customOverlayLayers() {
        let customConfig = MissionStrikeConfig(
            missionControlOverlayLayers: [99],
            minimumScreenCoverageFraction: 0.5,
            fallbackScreenSize: CGSize(width: 1920, height: 1080),
            ignoredWindowOwners: [],
            minimumOverlayAlpha: 0.01,
            minimumOverlayCount: 2,
            debounceInterval: 0.3
        )
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 99, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            mockWindowEntry(owner: "Dock", layer: 99, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen],
            config: customConfig
        ))
        // Default layer 18 should NOT match with this config
        let defaultLayerList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: defaultLayerList,
            screenSizes: [standardScreen],
            config: customConfig
        ))
    }

    @Test("Custom coverage fraction changes detection threshold")
    func customCoverageFraction() {
        let strictConfig = MissionStrikeConfig(
            missionControlOverlayLayers: [18, 20],
            minimumScreenCoverageFraction: 0.9,
            fallbackScreenSize: CGSize(width: 1920, height: 1080),
            ignoredWindowOwners: [],
            minimumOverlayAlpha: 0.01,
            minimumOverlayCount: 2,
            debounceInterval: 0.3
        )
        // 1600x900 covers 83% of 1920x1080 -- passes 50% but fails 90%
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1600, height: 900)),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1600, height: 900))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen],
            config: .default
        ))
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen],
            config: strictConfig
        ))
    }

    @Test("Custom minimumOverlayCount of 1 allows single overlay detection")
    func customMinimumOverlayCount() {
        let lenientConfig = MissionStrikeConfig(
            missionControlOverlayLayers: [18, 20],
            minimumScreenCoverageFraction: 0.5,
            fallbackScreenSize: CGSize(width: 1920, height: 1080),
            ignoredWindowOwners: [],
            minimumOverlayAlpha: 0.01,
            minimumOverlayCount: 1,
            debounceInterval: 0.3
        )
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen],
            config: lenientConfig
        ))
    }

    @Test("Transparent overlays are filtered even when count is sufficient")
    func transparentOverlaysFiltered() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 0.005),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 0.005)
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Mixed transparent and opaque overlays only count opaque ones")
    func mixedAlphaOverlays() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 0.0),
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 1.0)
        ]
        // Only 1 opaque overlay -- below the default minimumOverlayCount of 2
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }
}

// MARK: - Config Tests

@Suite("MissionStrikeConfig")
struct MissionStrikeConfigTests {

    @Test("Default config contains expected overlay layers")
    func defaultOverlayLayers() {
        let config = MissionStrikeConfig.default
        #expect(config.missionControlOverlayLayers == [18, 20])
    }

    @Test("Default config contains Dock in ignored owners")
    func defaultIgnoredOwners() {
        let config = MissionStrikeConfig.default
        #expect(config.ignoredWindowOwners.contains("Dock"))
        #expect(config.ignoredWindowOwners.contains("Window Server"))
        #expect(!config.ignoredWindowOwners.contains("Finder"))
    }

    @Test("Default config requires at least 2 qualifying overlays")
    func defaultOverlayCount() {
        let config = MissionStrikeConfig.default
        #expect(config.minimumOverlayCount == 2)
    }

    @Test("Default config filters near-zero alpha overlays")
    func defaultOverlayAlpha() {
        let config = MissionStrikeConfig.default
        #expect(config.minimumOverlayAlpha == 0.01)
    }
}
