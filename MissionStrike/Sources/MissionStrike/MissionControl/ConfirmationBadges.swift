import AppKit
import QuartzCore
import SwiftUI

/// Badges on thumbnails whose app put up a sheet when asked to close a window (unsaved changes,
/// running processes). The sheet is hidden behind Mission Control; the badge says so, and a click
/// on it goes to the window. Kept apart from the hover badge so holding the trigger modifier
/// doesn't cut one short.
@MainActor
final class ConfirmationBadges {
    static let shared = ConfirmationBadges()
    private init() {}

    /// Badges on screen, each with what keeps it there.
    private var badges: [(panel: NSPanel, isPending: @MainActor () -> Bool)] = []
    private var watcher: Task<Void, Never>?
    private static let pulses = 3
    private static let pulseDuration: TimeInterval = 0.35
    private static let checkInterval: Duration = .milliseconds(250)

    /// Shows a badge in the middle of a thumbnail, pulsing a few times to draw the eye. It stays
    /// while `isPending` holds and Mission Control is open; Mission Control is only left when
    /// the badge is clicked, which hides every badge and calls `onClick`.
    func show(
        _ style: HoverBadgeStyle,
        on thumbnail: CGRect,
        while isPending: @escaping @MainActor () -> Bool,
        onClick: @escaping @MainActor () -> Void
    ) {
        let panel = HoverBadgeController.makePanel()
        panel.ignoresMouseEvents = false
        let hostingView = ClickableBadgeView(rootView: HoverBadgeView(style: style))
        hostingView.onClick = {
            ConfirmationBadges.shared.dismiss()
            onClick()
        }
        hostingView.wantsLayer = true
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        let frame = NSRect(x: thumbnail.midX - size.width / 2, y: thumbnail.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        // Closing the same window again replaces its badge.
        badges.removeAll { badge in
            guard badge.panel.frame == frame else { return false }
            badge.panel.orderOut(nil)
            return true
        }
        badges.append((panel, isPending))
        hostingView.layer?.add(ActionFeedback.reduceMotion ? HoverBadgeController.fadeIn() : Self.pulse(), forKey: "pulse")
        panel.orderFrontRegardless()
        if let announcement = style.announcement {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        watch()
    }

    /// Input that closes Mission Control hides the badges straight away (`dismiss`); this
    /// catches the rest, like a sheet being answered behind Mission Control.
    private func watch() {
        guard watcher == nil else { return }
        watcher = Task { @MainActor in
            while !badges.isEmpty {
                try? await Task.sleep(for: Self.checkInterval)
                guard !Task.isCancelled else { return }
                guard MissionControlSession.isActive() else {
                    hideAll()
                    break
                }
                badges.removeAll { badge in
                    guard !badge.isPending() else { return false }
                    badge.panel.orderOut(nil)
                    return true
                }
            }
            watcher = nil
        }
    }

    /// Whether a point (AppKit screen coordinates) is on a badge, whose panel takes the click itself.
    func contains(_ point: CGPoint) -> Bool {
        badges.contains { $0.panel.isVisible && $0.panel.frame.contains(point) }
    }

    /// Fades in, alternates dim and bright for the first pulses, then holds bright.
    private static func pulse() -> CAKeyframeAnimation {
        let values: [Float] = [0, 1] + Array(repeating: [0.35, 1], count: pulses).flatMap { $0 }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.duration = pulseDuration * Double(values.count - 1)
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: values.count - 1
        )
        return animation
    }

    /// Hides every badge, e.g. when input is about to close Mission Control.
    func dismiss() {
        guard !badges.isEmpty else { return }
        watcher?.cancel()
        watcher = nil
        hideAll()
    }

    private func hideAll() {
        for badge in badges {
            badge.panel.orderOut(nil)
        }
        badges = []
    }
}

/// The confirmation badge's view: takes a click although MissionStrike isn't the active app,
/// and handles it itself rather than passing it to the badge's SwiftUI content.
private final class ClickableBadgeView: NSHostingView<HoverBadgeView> {
    var onClick: (@MainActor () -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
