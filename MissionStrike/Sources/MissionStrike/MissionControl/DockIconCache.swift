import AppKit
import CoreGraphics

/// Where the Dock and its running apps' icons were when last asked, in AX space.
struct DockSnapshot: Equatable, Sendable {
    /// What a middle-click at a point means for the Dock.
    enum Verdict: Equatable, Sendable {
        /// On a running app's icon: swallow the click and act on it.
        case runningApp
        /// On or near the Dock, but the snapshot can't say which icon: let the click go its
        /// usual way and ask the Dock afterwards.
        case maybe
        /// Nowhere near the Dock.
        case elsewhere
    }

    /// Room around the Dock for its edge and for icons that grew since the snapshot.
    private static let slack: CGFloat = 8

    var listFrames: [CGRect]
    var runningAppIcons: [CGRect]
    /// How far magnified icons can reach past their resting frames; 0 without magnification.
    var magnification: CGFloat = 0

    func verdict(at candidates: [CGPoint]) -> Verdict {
        // Magnified icons move with the pointer, so resting frames can't name the icon.
        if magnification == 0,
           runningAppIcons.contains(where: { icon in candidates.contains(where: icon.contains) }) {
            return .runningApp
        }
        return isOnDock(candidates) ? .maybe : .elsewhere
    }

    /// Whether any of the points is on or near the Dock, magnified icons included.
    func isOnDock(_ candidates: [CGPoint]) -> Bool {
        let reach = magnification + Self.slack
        return listFrames.contains { list in
            candidates.contains(where: list.insetBy(dx: -reach, dy: -reach).contains)
        }
    }

    /// The Dock as it shows when revealed: an auto-hidden Dock waits just past a screen edge,
    /// and Mission Control slides it onto the screen it is closest to.
    func revealed(on screens: [CGRect]) -> DockSnapshot {
        var revealed = self
        revealed.listFrames = listFrames.map { list in
            let center = CGPoint(x: list.midX, y: list.midY)
            guard let screen = screens.min(by: { $0.distance(to: center) < $1.distance(to: center) }) else {
                return list
            }
            var shown = list
            shown.origin.x = min(max(list.minX, screen.minX), screen.maxX - list.width)
            shown.origin.y = min(max(list.minY, screen.minY), screen.maxY - list.height)
            return shown
        }
        // Icons move with the Dock; they are only used for middle-clicks, which probe instead.
        revealed.runningAppIcons = []
        return revealed
    }

    /// Whether the Dock was showing, rather than hidden off screen, when this was taken.
    func isShown(on screens: [CGRect]) -> Bool {
        listFrames.contains { list in
            let area = list.width * list.height
            return area > 0 && screens.contains { screen in
                let overlap = screen.intersection(list)
                return !overlap.isNull && overlap.width * overlap.height >= area / 2
            }
        }
    }
}

/// Keeps a `DockSnapshot` fresh outside the event tap, so the tap can tell whether a
/// middle-click is on a running app's Dock icon without asking the Dock. The Dock also draws
/// Mission Control and can be slow to answer; waiting on it in the tap holds up all input.
@MainActor
final class DockIconCache {
    static let shared = DockIconCache()
    private init() {}

    /// A snapshot older than this is taken again before it is trusted.
    private static let maxAge: Duration = .seconds(300)
    /// The Dock animates icons in and out when apps launch or quit.
    private static let settleDelay: Duration = .milliseconds(700)

    private var snapshot: DockSnapshot?
    private var capturedAt: ContinuousClock.Instant?
    private var refreshTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Cheap enough for the event tap: one window-list lookup, no Accessibility.
    func verdict(at candidates: [CGPoint]) -> DockSnapshot.Verdict {
        guard Self.isDockOnScreen(at: candidates) else { return .elsewhere }
        guard let snapshot, let capturedAt, ContinuousClock.now - capturedAt < Self.maxAge,
              snapshot.isShown(on: ScreenCoordinates.axScreenFrames) else {
            // Missing, old, or taken while an auto-hidden Dock was off screen.
            scheduleRefresh()
            return .maybe
        }
        return snapshot.verdict(at: candidates)
    }

    /// Whether the points are on the Dock as Mission Control shows it, auto-hidden or not.
    /// False when that isn't known: a right-click there then opens MissionStrike's menu, as it
    /// did before the Dock was checked.
    func isOnDock(at candidates: [CGPoint]) -> Bool {
        guard let snapshot, let capturedAt, ContinuousClock.now - capturedAt < Self.maxAge else {
            scheduleRefresh()
            return false
        }
        return snapshot.revealed(on: ScreenCoordinates.axScreenFrames).isOnDock(candidates)
    }

    /// Re-takes the snapshot whenever the Dock's icons are likely to have moved.
    func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockIconCache.shared.scheduleRefresh(after: Self.settleDelay) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DockIconCache.shared.scheduleRefresh(after: Self.settleDelay) }
        })
        scheduleRefresh()
    }

    func scheduleRefresh(after delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            DockIconCache.shared.refresh()
        }
    }

    private func refresh() {
        snapshot = DockHitTester.snapshot()
        capturedAt = .now
    }

    /// Whether a Dock window is on screen under any of the points. An auto-hidden Dock takes
    /// its window off screen, so clicks where it would appear stay with the app below.
    private static func isDockOnScreen(at candidates: [CGPoint]) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            // Negative layers are desktop pictures, never the Dock itself.
            guard info[kCGWindowOwnerName as String] as? String == "Dock",
                  (info[kCGWindowLayer as String] as? Int ?? 0) >= 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return false
            }
            return candidates.contains(where: bounds.contains)
        }
    }
}

private extension CGRect {
    /// How far a point is from the rectangle; 0 inside it.
    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
