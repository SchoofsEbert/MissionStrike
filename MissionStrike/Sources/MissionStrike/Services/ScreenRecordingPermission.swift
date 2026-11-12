import AppKit
import Observation

/// Whether window previews are on but Screen Recording isn't allowed, for the menu bar's warning
/// and Settings.
///
/// macOS sends no notification for this permission, unlike Accessibility, so it's checked when
/// it may have changed: at launch, when a setting changes, when MissionStrike comes forward,
/// whenever the picker wants previews, and every few seconds while the warning shows. A new
/// grant often only counts after a relaunch, which macOS offers itself.
@MainActor
@Observable
final class ScreenRecordingPermission {
    static let shared = ScreenRecordingPermission()
    private init() {}

    /// Nil until the first check.
    private(set) var isAllowed: Bool?

    /// Previews are on, and macOS won't let MissionStrike take them.
    var isMissing: Bool {
        wanted && isAllowed == false
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var poll: Task<Void, Never>?
    private var wanted = false
    private static let pollInterval: Duration = .seconds(5)

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

    /// Checks off the main thread: each check takes several milliseconds.
    func check() {
        Task {
            report(await Task.detached { SnapPreviews.isAllowed }.value)
        }
    }

    /// What a check elsewhere (the picker's) found.
    func report(_ allowed: Bool) {
        let changed = allowed != isAllowed
        isAllowed = allowed
        if changed {
            StatusBarController.shared.refresh()
        }
        updatePolling()
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
        // Read from UserDefaults: SettingsStore may not have reloaded yet when this runs.
        let wanted = Self.previewsWanted()
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        StatusBarController.shared.refresh()
        if wanted {
            check()
        } else {
            updatePolling()
        }
    }

    private func updatePolling() {
        let shouldPoll = wanted && isAllowed == false
        if shouldPoll, poll == nil {
            poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard !Task.isCancelled else { return }
                    check()
                }
            }
        } else if !shouldPoll, let poll {
            poll.cancel()
            self.poll = nil
        }
    }
}
