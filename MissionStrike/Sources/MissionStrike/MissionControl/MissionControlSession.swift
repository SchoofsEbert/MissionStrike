import AppKit

extension Notification.Name {
    /// Posted on the main thread when a session starts: Mission Control was first seen open.
    /// Can be posted from inside the event tap callback, so observers must only do cheap work.
    static let missionControlDidOpen = Notification.Name("io.github.schoofsebert.missionstrike.missionControlDidOpen")
    /// Posted on the main thread when the session ends, under the same rules.
    static let missionControlDidClose = Notification.Name("io.github.schoofsebert.missionstrike.missionControlDidClose")
}

/// The Mission Control that is open now, and what MissionStrike has looked up in it.
///
/// Hit-testing near the Spaces strip used to walk WindowManager's whole Accessibility tree
/// several times per click and per hover-badge tick. A session starts when Mission Control is
/// first seen open and ends once it closes, so those lookups happen once per opening.
@MainActor
final class MissionControlSession {
    // MARK: - Detection

    /// How long a detection result is reused. Input comes in bursts (a click and its release,
    /// key repeats, hover ticks); one window-list copy serves the burst.
    static let detectionTTL: Duration = .milliseconds(75)
    /// How often an open session checks whether Mission Control has closed.
    private static let watchInterval: TimeInterval = 0.25

    /// The open session; nil once Mission Control has been seen closed.
    private(set) static var current: MissionControlSession?
    private static var lastDetection: (at: ContinuousClock.Instant, isActive: Bool)?
    /// The window list the last detection looked at, for diagnostics.
    private(set) static var lastWindowList: [[String: Any]] = []
    private static var watcher: Timer?

    /// Whether Mission Control is open, reusing a check made within `maxAge`. Pass `.zero`
    /// right before acting, so a Mission Control that has just closed is never acted on.
    static func isActive(maxAge: Duration = detectionTTL) -> Bool {
        let now = ContinuousClock.now
        if let lastDetection, now - lastDetection.at < maxAge {
            return lastDetection.isActive
        }
        let detection = MissionControlDetector().detect()
        lastDetection = (now, detection.isActive)
        lastWindowList = detection.windowList
        if detection.isActive {
            begin()
        } else {
            end()
        }
        return detection.isActive
    }

    /// Mission Control's key or a trackpad swipe can close and reopen it: start over.
    static func reset() {
        lastDetection = nil
        end()
    }

    /// Input that went through to Mission Control can close it or change its Spaces (a click
    /// on "+", a Space or a window): check again next time, and look the Spaces up again.
    static func inputPassedThrough() {
        lastDetection = nil
        current?.forgetSpaces()
    }

    private static func begin() {
        guard current == nil else { return }
        current = MissionControlSession()
        let watcher = Timer(timeInterval: watchInterval, repeats: true) { _ in
            MainActor.assumeIsolated { _ = MissionControlSession.isActive(maxAge: .zero) }
        }
        RunLoop.main.add(watcher, forMode: .common)
        Self.watcher = watcher
        NotificationCenter.default.post(name: .missionControlDidOpen, object: nil)
    }

    private static func end() {
        watcher?.invalidate()
        watcher = nil
        guard current != nil else { return }
        current = nil
        NotificationCenter.default.post(name: .missionControlDidClose, object: nil)
    }

    // MARK: - Cached lookups

    /// How long Spaces Bar lookups are trusted. On older macOS the bar rebuilds its buttons
    /// when it expands under the pointer, without any input MissionStrike sees.
    private static let spacesLookupTTL: Duration = .seconds(1)

    let mainDisplayHeight = ScreenCoordinates.mainDisplayHeight
    private(set) lazy var windowManager: AXElement? = Self.findWindowManager()
    private var spacesBar: (element: AXElement?, at: ContinuousClock.Instant)?
    private var desktopButtons: [AXElement: (buttons: [AXElement], at: ContinuousClock.Instant)] = [:]

    /// Drops what was found in the Spaces Bar, e.g. after a Space was removed.
    func forgetSpaces() {
        spacesBar = nil
        desktopButtons = [:]
    }

    /// The app windows Mission Control shows, with their thumbnails; nil before macOS 27, where
    /// thumbnails carry no window ID.
    func windowThumbnails() -> [WindowThumbnail]? {
        guard flipsY, let windowManager else { return nil }
        return MissionControlHitTester.windowThumbnails(in: windowManager, environment: self)
    }

    /// The thumbnail button showing a window, to press it; nil before macOS 27, where
    /// thumbnails carry no window ID.
    func thumbnailButton(for windowID: CGWindowID) -> AXElement? {
        guard flipsY, let windowManager else { return nil }
        return MissionControlHitTester.thumbnailButtons(in: windowManager).first { $0.windowID == windowID }?.element
    }

    private static func findWindowManager() -> AXElement? {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first
            ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == "WindowManager" }
        return app.map { AXElement.application($0.processIdentifier) }
    }

    private static func isFresh(_ time: ContinuousClock.Instant) -> Bool {
        ContinuousClock.now - time < spacesLookupTTL
    }
}

extension MissionControlSession: HitTestEnvironment {
    var flipsY: Bool { MissionControlHitTester.shouldYFlipForMissionControl() }

    func element(at point: CGPoint) -> AXElement? {
        AXElement.at(point)
    }

    func spacesBarFrame() -> CGRect? {
        if let spacesBar {
            // A bar that has gone reads no frame: look it up again.
            if let frame = spacesBar.element?.frame { return frame }
            if spacesBar.element == nil, Self.isFresh(spacesBar.at) { return nil }
        }
        let element = windowManager.flatMap { MissionControlHitTester.firstDescendant(of: $0, titled: "Spaces Bar") }
        spacesBar = (element, .now)
        return element?.frame
    }

    func desktops(in bar: AXElement?) -> [(element: AXElement, frame: CGRect)] {
        guard let root = bar ?? windowManager else { return [] }
        if let cached = desktopButtons[root], Self.isFresh(cached.at) {
            let framed = MissionControlHitTester.framed(cached.buttons)
            // Every button still there, so none was rebuilt.
            if framed.count == cached.buttons.count { return framed }
        }
        let buttons = MissionControlHitTester.removableDesktopButtons(in: root)
        desktopButtons[root] = (buttons, .now)
        return MissionControlHitTester.framed(buttons)
    }

    func appWindow(withID windowID: CGWindowID) -> AppWindow? {
        WindowList.appWindow(withID: windowID)
    }

    func isSystemOverlay(_ element: AXElement) -> Bool {
        guard let pid = element.pid,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName else {
            return false
        }
        return MissionStrikeConfig.default.ignoredWindowOwners.contains(name)
    }
}
