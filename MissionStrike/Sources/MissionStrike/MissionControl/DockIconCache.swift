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
        let reach = magnification + Self.slack
        let nearDock = listFrames.contains { list in
            candidates.contains(where: list.insetBy(dx: -reach, dy: -reach).contains)
        }
        return nearDock ? .maybe : .elsewhere
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
        guard SettingsStore.shared.current.enableDockMiddleClick else {
            snapshot = nil
            return
        }
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
