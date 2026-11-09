import Foundation

/// Centralizes all tunable constants used across MissionStrike.
/// Adjust these values when macOS changes Mission Control behavior
/// in future versions (e.g., new Dock overlay layer numbers).
struct MissionStrikeConfig: Sendable {

    // MARK: - Mission Control Detection

    /// Dock overlay window layers observed during Mission Control (macOS 13–26).
    /// Real sessions typically expose two large Dock overlays (e.g. layers 18 and 20).
    let missionControlOverlayLayers: Set<Int>

    /// Companion overlays that also appear during Mission Control but are not
    /// owned by Dock. On macOS 27+, the second full-screen surface moved to
    /// WindowManager at layer 19; Dock only exposes a single layer-20 overlay.
    /// Keys are `kCGWindowOwnerName` values; values are matching layer numbers.
    let missionControlCompanionOverlays: [String: Set<Int>]

    /// Minimum fraction of a screen's dimensions an overlay must cover
    /// to be considered a Mission Control overlay.
    let minimumScreenCoverageFraction: CGFloat

    /// Fallback screen size used when `NSScreen.screens` is empty (headless config).
    let fallbackScreenSize: CGSize

    // MARK: - Window Targeting

    /// Window owner names ignored during CGWindow fallback lookup.
    let ignoredWindowOwners: Set<String>

    // MARK: - Overlay Filtering

    /// Minimum window alpha for an overlay to be considered visible.
    /// Transparent hit-test overlays (e.g. dock auto-show, app-bounce)
    /// are filtered out when their alpha is below this threshold.
    let minimumOverlayAlpha: CGFloat

    /// Minimum number of qualifying Mission Control overlays required to
    /// consider Mission Control active. At least one must be a Dock overlay;
    /// the rest may be companion overlays (e.g. WindowManager on macOS 27+).
    /// A dock bounce typically produces at most one Dock overlay and no
    /// companion overlays, so this still rejects that false positive.
    let minimumOverlayCount: Int

    // MARK: - Event Tap

    /// Minimum interval (seconds) between processed clicks to prevent
    /// racing close operations on rapid double-clicks.
    let debounceInterval: TimeInterval

    // MARK: - Tab Swipe

    /// How far three fingers travel sideways before the first tab switch, in trackpad widths.
    let tabSwipeFirstStep: CGFloat

    /// How much further they travel for each tab after that, so a longer swipe goes further.
    let tabSwipeRepeatStep: CGFloat

    /// Vertical travel that makes a swipe Mission Control's or App Exposé's before it switches a tab.
    let tabSwipeVerticalLimit: CGFloat

    // MARK: - Default Configuration

    static let `default` = MissionStrikeConfig(
        missionControlOverlayLayers: [18, 20],
        missionControlCompanionOverlays: ["WindowManager": [19]],
        minimumScreenCoverageFraction: 0.5,
        fallbackScreenSize: CGSize(width: 1920, height: 1080),
        ignoredWindowOwners: ["Dock", "Window Server", "Wallpaper", "WindowManager"],
        minimumOverlayAlpha: 0.01,
        minimumOverlayCount: 2,
        debounceInterval: 0.3,
        tabSwipeFirstStep: 0.06,
        tabSwipeRepeatStep: 0.12,
        tabSwipeVerticalLimit: 0.05
    )
}
