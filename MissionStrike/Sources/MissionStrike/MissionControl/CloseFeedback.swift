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

/// A window whose close button was pressed, until it's seen gone.
struct PendingClose {
    let window: AXElement
    let pid: pid_t
    let windowID: CGWindowID?
    /// Its thumbnail in AppKit screen coordinates, when known.
    var thumbnail: CGRect?

    init(window: AXElement, pid: pid_t, thumbnail: CGRect? = nil) {
        self.window = window
        self.pid = pid
        self.windowID = window.windowID
        self.thumbnail = thumbnail
    }

    @MainActor
    func state() -> WindowCloseState {
        // The window list knows at once when a window is destroyed, even if the app is slow to answer.
        if let windowID, WindowList.appWindow(withID: windowID) == nil {
            return .gone
        }
        guard let windows = AXElement.application(pid).windows else {
            // Can't ask the app: it may be busy closing, so let it run into the timeout.
            return .open(hasSheet: false)
        }
        // An app that keeps the window around after closing it drops it from its window list.
        guard let window = windows.first(where: isSameWindow) else {
            return .gone
        }
        return .open(hasSheet: window.children.contains { $0.role == kAXSheetRole })
    }

    private func isSameWindow(_ candidate: AXElement) -> Bool {
        if let windowID {
            return candidate.windowID == windowID
        }
        return candidate == window
    }
}

extension MissionControlManager {
    private static let closeCheckInterval: Duration = .milliseconds(100)
    /// How long an app gets to close a window or put up a sheet before the close counts as failed.
    private static let closeCheckTimeout: Duration = .seconds(1)

    /// Waits until each pressed close has an outcome, then shows it: a poof where a window went,
    /// the confirmation badge where an app asks first. `anchor` stands in for windows whose
    /// thumbnail isn't known, and gets one poof however many of them closed.
    func watch(_ closes: [PendingClose], anchor: CGRect?) {
        guard !closes.isEmpty else { return }
        Task { @MainActor in
            let start = ContinuousClock.now
            var waiting = closes
            var poofedAtAnchor = false
            while !waiting.isEmpty {
                try? await Task.sleep(for: Self.closeCheckInterval)
                let timedOut = ContinuousClock.now - start >= Self.closeCheckTimeout
                var stillWaiting: [PendingClose] = []
                for close in waiting {
                    switch CloseOutcome.decide(close.state(), timedOut: timedOut) {
                    case nil:
                        stillWaiting.append(close)
                    case .closed:
                        HoverBadgeController.shared.layoutMayHaveChanged()
                        if let thumbnail = close.thumbnail {
                            CloseEffect.play(at: NSPoint(x: thumbnail.midX, y: thumbnail.midY))
                        } else if let anchor, !poofedAtAnchor {
                            poofedAtAnchor = true
                            CloseEffect.play(at: NSPoint(x: anchor.midX, y: anchor.midY))
                        }
                    case .needsConfirmation:
                        logger.debug("Close is waiting on a confirmation sheet.")
                        guard let thumbnail = close.thumbnail ?? anchor else { break }
                        HoverBadgeController.shared.flash(.needsConfirmation, on: thumbnail) {
                            close.state() == .open(hasSheet: true)
                        }
                    case .failed:
                        logger.warning("Window still open without a sheet after its close button was pressed.")
                    }
                }
                waiting = stillWaiting
            }
        }
    }
}
