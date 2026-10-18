import AppKit
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "MissionControl")

/// A window as seen some time after its close button was pressed.
enum WindowCloseState: Equatable {
    case gone
    case open(hasSheet: Bool)
}

/// What became of a close.
enum CloseOutcome: Equatable {
    case closed
    /// The app put up a sheet (unsaved changes, running processes) and waits for an answer.
    case needsConfirmation
    /// Still there without a sheet after the app had its time.
    case failed

    /// The outcome once it can be told; nil while the app may still be closing the window.
    static func decide(_ state: WindowCloseState, timedOut: Bool) -> CloseOutcome? {
        switch state {
        case .gone: .closed
        case .open(hasSheet: true): .needsConfirmation
        case .open(hasSheet: false): timedOut ? .failed : nil
        }
    }
}

/// A window whose close button was pressed, until it's seen gone. Made before pressing: a
/// closed window no longer tells its window ID.
struct PendingClose {
    let window: AXElement
    let pid: pid_t
    let windowID: CGWindowID?
    /// Its thumbnail in AppKit screen coordinates, when known.
    var thumbnail: CGRect?

    /// The window as the app lists it now, if it still does.
    @MainActor
    func currentWindow() -> AXElement? {
        AXElement.application(pid).windows?.first(where: isSameWindow)
    }

    @MainActor
    func state() -> WindowCloseState {
        Self.states(of: [self])[0]
    }

    /// Each close's state, from one window-list call and asking each app for its windows once.
    @MainActor
    static func states(of closes: [PendingClose]) -> [WindowCloseState] {
        CloseStates.of(closes.map { ($0.pid, $0.windowID, $0.window) }, in: LiveCloseStateEnvironment())
    }

    private func isSameWindow(_ candidate: AXElement) -> Bool {
        if let windowID {
            return candidate.windowID == windowID
        }
        return candidate == window
    }
}

/// What telling whether windows closed asks of the system. The live environment asks the
/// window list and Accessibility; tests count what they're asked.
@MainActor
protocol CloseStateEnvironment {
    associatedtype Window: Hashable
    /// Which of these CGWindowIDs are still app windows in the window list.
    func listedWindowIDs(_ windowIDs: [CGWindowID]) -> Set<CGWindowID>
    /// The app's windows; nil when it can't be asked.
    func windows(of pid: pid_t) -> [Window]?
    func windowID(of window: Window) -> CGWindowID?
    func hasSheet(_ window: Window) -> Bool
}

@MainActor
enum CloseStates {
    /// Each close's state, from one window-list call and asking each app for its windows once.
    /// A window is asked for its ID only when a match needs it, and only once.
    static func of<Environment: CloseStateEnvironment>(
        _ closes: [(pid: pid_t, windowID: CGWindowID?, window: Environment.Window)],
        in environment: Environment
    ) -> [WindowCloseState] {
        // The window list knows at once when a window is destroyed, even if the app is slow to answer.
        let listed = environment.listedWindowIDs(closes.compactMap(\.windowID))
        var windowsByApp: [pid_t: [Environment.Window]?] = [:]
        var windowIDs: [Environment.Window: CGWindowID?] = [:]
        var states: [WindowCloseState] = []
        for close in closes {
            if let windowID = close.windowID, !listed.contains(windowID) {
                states.append(.gone)
                continue
            }
            let windows: [Environment.Window]?
            if let asked = windowsByApp[close.pid] {
                windows = asked
            } else {
                windows = environment.windows(of: close.pid)
                windowsByApp[close.pid] = .some(windows)
            }
            guard let windows else {
                // Can't ask the app: it may be busy closing, so let it run into the timeout.
                states.append(.open(hasSheet: false))
                continue
            }
            // An app that keeps the window around after closing it drops it from its window list.
            let match = windows.first { candidate in
                guard let windowID = close.windowID else { return candidate == close.window }
                if let known = windowIDs[candidate] {
                    return known == windowID
                }
                let candidateID = environment.windowID(of: candidate)
                windowIDs[candidate] = .some(candidateID)
                return candidateID == windowID
            }
            guard let window = match else {
                states.append(.gone)
                continue
            }
            states.append(.open(hasSheet: environment.hasSheet(window)))
        }
        return states
    }
}

@MainActor
private struct LiveCloseStateEnvironment: CloseStateEnvironment {
    func listedWindowIDs(_ windowIDs: [CGWindowID]) -> Set<CGWindowID> {
        Set(WindowList.appWindows(withIDs: windowIDs).keys)
    }

    func windows(of pid: pid_t) -> [AXElement]? {
        AXElement.application(pid).windows
    }

    func windowID(of window: AXElement) -> CGWindowID? {
        window.windowID
    }

    func hasSheet(_ window: AXElement) -> Bool {
        window.children.contains { $0.role == kAXSheetRole }
    }
}

extension MissionControlManager {
    private static let closeCheckInterval: Duration = .milliseconds(100)
    /// How long an app gets to close a window or put up a sheet before the close counts as failed.
    private static let closeCheckTimeout: Duration = .seconds(1)
    /// How long Mission Control takes to move the remaining thumbnails after some have gone.
    private static let relayoutDelay: Duration = .milliseconds(500)

    /// Waits until each pressed close has an outcome, then shows it: a poof where a window went,
    /// the confirmation badge where an app asks first, the failure badge where nothing happened,
    /// and one haptic for the lot. `anchor` stands in for windows whose thumbnail isn't known,
    /// and gets one poof however many of them closed.
    func watch(_ closes: [PendingClose], anchor: CGRect?) {
        guard !closes.isEmpty else { return }
        Task { @MainActor in
            let start = ContinuousClock.now
            var batch = CloseBatch(anchor: anchor)
            var waiting = closes
            while !waiting.isEmpty {
                try? await Task.sleep(for: Self.closeCheckInterval)
                let timedOut = ContinuousClock.now - start >= Self.closeCheckTimeout
                waiting = zip(waiting, PendingClose.states(of: waiting)).compactMap { close, state in
                    guard let outcome = CloseOutcome.decide(state, timedOut: timedOut) else { return close }
                    batch.record(outcome, for: close)
                    return nil
                }
            }
            if batch.failed {
                ActionFeedback.failed(at: batch.failurePlaces)
            }
            var asking = batch.asking
            if batch.anyClosed, asking.contains(where: { $0.thumbnail != nil }) {
                // The windows that closed leave room the rest move into: badge them where they end up.
                try? await Task.sleep(for: Self.relayoutDelay)
                let thumbnails = MissionControlSession.current?.windowThumbnails() ?? []
                for index in asking.indices {
                    let windowID = asking[index].windowID
                    if let moved = thumbnails.first(where: { $0.window.windowID == windowID }) {
                        asking[index].thumbnail = moved.frame
                    }
                }
            }
            for close in asking {
                showConfirmationBadge(for: close, anchor: anchor)
            }
        }
    }

    private func showConfirmationBadge(for close: PendingClose, anchor: CGRect?) {
        // The sheet is only hidden while Mission Control is open.
        guard let thumbnail = close.thumbnail ?? anchor, MissionControlSession.isActive() else { return }
        let appName = NSRunningApplication(processIdentifier: close.pid)?.localizedName
        ConfirmationBadges.shared.show(
            .needsConfirmation(appName: appName),
            on: thumbnail,
            while: { close.state() == .open(hasSheet: true) },
            onClick: { MissionControlManager.shared.goToWindow(close) }
        )
    }

    /// How long leaving Mission Control may take before it's toggled off.
    private static let leaveMissionControlTimeout: Duration = .seconds(1)

    /// Leaves Mission Control for a window whose app asks before closing it, so its sheet can be
    /// answered.
    func goToWindow(_ close: PendingClose) {
        // Pressing the thumbnail leaves Mission Control the way clicking it does (macOS 27+).
        if let windowID = close.windowID, let thumbnail = MissionControlSession.current?.thumbnailButton(for: windowID) {
            thumbnail.perform(kAXPressAction)
        }
        (close.currentWindow() ?? close.window).perform(kAXRaiseAction)
        NSRunningApplication(processIdentifier: close.pid)?.activate()
        Task { @MainActor in
            try? await Task.sleep(for: Self.leaveMissionControlTimeout)
            guard MissionControlSession.isActive(maxAge: .zero) else { return }
            // Opening Mission Control while it's open closes it, like its key does.
            logger.debug("Mission Control still open after going to the window; toggling it off.")
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}

/// The outcomes of closes pressed together. Closed windows get their poof and the batch its
/// haptic as they go; failures and confirmations are shown once every outcome is in.
@MainActor
private struct CloseBatch {
    let anchor: CGRect?
    private(set) var anyClosed = false
    private(set) var failed = false
    /// Where to put failure badges, each place once.
    private(set) var failurePlaces: [CGRect] = []
    /// Windows whose app put up a sheet.
    private(set) var asking: [PendingClose] = []
    private var poofedAtAnchor = false

    init(anchor: CGRect?) {
        self.anchor = anchor
    }

    mutating func record(_ outcome: CloseOutcome, for close: PendingClose) {
        switch outcome {
        case .closed:
            if !anyClosed {
                anyClosed = true
                ActionFeedback.succeeded()
            }
            HoverBadgeController.shared.layoutMayHaveChanged()
            if let thumbnail = close.thumbnail {
                CloseEffect.play(at: NSPoint(x: thumbnail.midX, y: thumbnail.midY))
            } else if let anchor, !poofedAtAnchor {
                poofedAtAnchor = true
                CloseEffect.play(at: NSPoint(x: anchor.midX, y: anchor.midY))
            }
        case .needsConfirmation:
            logger.debug("Close is waiting on a confirmation sheet.")
            asking.append(close)
        case .failed:
            logger.warning("Window still open without a sheet after its close button was pressed.")
            failed = true
            if let place = close.thumbnail ?? anchor, !failurePlaces.contains(place) {
                failurePlaces.append(place)
            }
        }
    }
}
