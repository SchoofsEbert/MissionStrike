import Foundation

/// Centralizes all tunable constants used across MissionStrike.
/// Adjust these values when macOS changes Mission Control behavior
/// in future versions (e.g., new Dock overlay layer numbers).
struct MissionStrikeConfig: Sendable {

    // MARK: - Mission Control Detection

    /// Dock overlay window layers observed during Mission Control (macOS 13–15).
    let missionControlOverlayLayers: Set<Int>

    /// Minimum fraction of a screen's dimensions a Dock overlay must cover
    /// to be considered a Mission Control overlay.
    let minimumScreenCoverageFraction: CGFloat

    /// Fallback screen size used when `NSScreen.screens` is empty (headless config).
    let fallbackScreenSize: CGSize

    // MARK: - Window Targeting

    /// Window owner names ignored during CGWindow fallback lookup.
    let ignoredWindowOwners: Set<String>

    // MARK: - Event Tap

    /// Minimum interval (seconds) between processed clicks to prevent
    /// racing close operations on rapid double-clicks.
    let debounceInterval: TimeInterval

    // MARK: - Default Configuration

    static let `default` = MissionStrikeConfig(
        missionControlOverlayLayers: [18, 20],
        minimumScreenCoverageFraction: 0.5,
        fallbackScreenSize: CGSize(width: 1920, height: 1080),
        ignoredWindowOwners: ["Dock", "Window Server", "Wallpaper"],
        debounceInterval: 0.3
    )
}
