import AppKit
import Observation

/// Whether window previews are on but Screen Recording isn't allowed, for Settings to say so.
/// Previews are optional, so this is a note there, not a warning in the menu bar.
///
/// macOS sends no notification for this permission, unlike Accessibility, so while previews are
/// on it's checked when it may have changed: when they're turned on, when MissionStrike comes
/// forward (back from System Settings), and whenever the picker wants previews. A new grant often
/// only counts after a relaunch, which macOS offers itself.
@MainActor
@Observable
final class ScreenRecordingPermission {
    static let shared = ScreenRecordingPermission()
    private init() {}

    /// Nil until the first check.
    private(set) var isAllowed: Bool?
    private var wanted = false

    /// Previews are on, and macOS won't let MissionStrike take them.
    var isMissing: Bool {
        wanted && isAllowed == false
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static func previewsWanted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(.enableWindowSnapping) && defaults.bool(.enableSnapAssist) && defaults.bool(.showSnapPreviews)
    }

    static let privacySettings = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )! // swiftlint:disable:this force_unwrapping

    func startObserving() {
        guard observers.isEmpty else { return }
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ScreenRecordingPermission.shared.settingsChanged() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ScreenRecordingPermission.shared.check() }
            }
        ]
        wanted = Self.previewsWanted()
        check()
    }

    /// Checks off the main thread, each check taking several milliseconds, and only while
    /// previews are on.
    func check() {
        guard wanted else { return }
        Task {
            report(await Task.detached { SnapPreviews.isAllowed }.value)
        }
    }

    /// What a check elsewhere (the picker's) found.
    func report(_ allowed: Bool) {
        if allowed != isAllowed {
            isAllowed = allowed
        }
    }

    /// Asks macOS, which shows its prompt only the first time; after that, it's changed in
    /// Privacy settings.
    func request() {
        Task.detached {
            CGRequestScreenCaptureAccess()
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(Self.privacySettings)
    }

    /// Defaults change for many reasons; only turning previews on or off matters here.
    private func settingsChanged() {
        let wanted = Self.previewsWanted()
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        check()
    }
}
