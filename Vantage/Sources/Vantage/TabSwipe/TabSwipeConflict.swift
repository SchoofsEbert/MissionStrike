import Foundation

/// Trackpad gestures of macOS's own that also take a three-finger sideways swipe, so both would act.
enum TabSwipeConflict: String, CaseIterable, Identifiable {
    case swipeBetweenPages
    case swipeBetweenFullScreenApps
    case threeFingerDrag

    var id: Self { self }

    var message: String {
        switch self {
        case .swipeBetweenPages:
            "Swipe between pages also uses three fingers. Set it to two fingers in Trackpad settings."
        case .swipeBetweenFullScreenApps:
            "Swipe between full-screen applications also uses three fingers. Set it to four fingers in Trackpad settings."
        case .threeFingerDrag:
            "Three-finger drag is on, so swiping drags windows too. It's under Accessibility › Pointer Control › Trackpad Options."
        }
    }

    /// From the trackpad's `TrackpadThreeFingerHorizSwipeGesture` (1 pages, 2 full-screen apps)
    /// and `TrackpadThreeFingerDrag`.
    static func conflicts(horizontalSwipe: Int, threeFingerDrag: Bool) -> [TabSwipeConflict] {
        var conflicts: [TabSwipeConflict] = []
        switch horizontalSwipe {
        case 1: conflicts.append(.swipeBetweenPages)
        case 2: conflicts.append(.swipeBetweenFullScreenApps)
        default: break
        }
        if threeFingerDrag {
            conflicts.append(.threeFingerDrag)
        }
        return conflicts
    }

    /// The built-in trackpad and a Magic Trackpad keep their own copy; either one conflicting counts.
    private static let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]

    static func current() -> [TabSwipeConflict] {
        let found = domains.flatMap { domain in
            // Changed by System Settings, not this process: drop the cached copy first.
            CFPreferencesAppSynchronize(domain as CFString)
            func value(_ key: String) -> Int {
                (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.intValue ?? 0
            }
            return conflicts(
                horizontalSwipe: value("TrackpadThreeFingerHorizSwipeGesture"),
                threeFingerDrag: value("TrackpadThreeFingerDrag") != 0
            )
        }
        return allCases.filter(found.contains)
    }
}
