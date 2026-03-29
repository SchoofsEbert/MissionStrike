@testable import MissionStrike
import CoreGraphics
import Testing

// MARK: - Test Helpers

/// Builds a mock CGWindowList entry matching the shape returned by CGWindowListCopyWindowInfo.
private func mockWindowEntry(
    owner: String,
    layer: Int,
    bounds: CGRect
) -> [String: Any] {
    [
        kCGWindowOwnerName as String: owner,
        kCGWindowLayer as String: layer,
        kCGWindowBounds as String: [
            "X": bounds.origin.x,
            "Y": bounds.origin.y,
            "Width": bounds.width,
            "Height": bounds.height
        ]
    ]
}

private let standardScreen = CGSize(width: 1920, height: 1080)
private let smallScreen = CGSize(width: 1280, height: 800)

// MARK: - Detection Heuristic Tests

@Suite("Mission Control Detection")
struct MissionControlDetectionTests {

    // MARK: - Positive detection

    @Test("Dock overlay at layer 18 covering full screen is detected")
    func dockOverlayLayer18() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Dock overlay at layer 20 covering full screen is detected")
    func dockOverlayLayer20() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    // MARK: - Negative detection

    @Test("Dock overlay that is too small for any screen is not detected")
    func dockOverlayTooSmall() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 200, height: 50))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Non-Dock window at Mission Control layer is not detected")
    func nonDockOwnerIgnored() {
        let windowList = [
            mockWindowEntry(owner: "SomeOtherApp", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen]
        ))
    }

    @Test("Dock window at non-Mission-Control layer is not detected")
    func dockWrongLayer() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
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
        // Overlay is 1280×800 — too small for the 1920×1080 primary,
        // but covers the 1280×800 secondary.
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen, smallScreen]
        ))
    }

    @Test("Overlay too small for ALL screens is not detected on multi-display")
    func multiDisplayTooSmallForAll() {
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        ]
        #expect(!MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen, smallScreen]
        ))
    }

    // MARK: - Fallback screen size

    @Test("Empty screen list uses fallback dimensions")
    func fallbackScreenSize() {
        // Overlay covers default fallback (1920×1080 × 0.5 = 960×540)
        let windowList = [
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
            debounceInterval: 0.3
        )
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 99, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        #expect(MissionControlActiveChecker.isActive(
            windowList: windowList,
            screenSizes: [standardScreen],
            config: customConfig
        ))
        // Default layer 18 should NOT match with this config
        let defaultLayerList = [
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
            debounceInterval: 0.3
        )
        // 1600×900 covers 83% of 1920×1080 — passes 50% but fails 90%
        let windowList = [
            mockWindowEntry(owner: "Dock", layer: 18, bounds: CGRect(x: 0, y: 0, width: 1600, height: 900))
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
}
