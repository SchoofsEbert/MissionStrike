import AppKit
import QuartzCore
import SwiftUI

/// What a modifier-click would do to the hovered thumbnail, shown as a traffic-light badge.
enum HoverBadgeStyle: Equatable {
    case close
    case minimize
    case closeAll
    /// Flashed after a close when the app put up a sheet (unsaved changes, running processes).
    case needsConfirmation(appName: String?)
    /// Shaken when an action didn't go through.
    case failed

    init(flags: CGEventFlags) {
        switch MouseAction(flags: flags) {
        case .close: self = .close
        case .minimize: self = .minimize
        case .closeAll: self = .closeAll
        }
    }

    /// Text next to the circle, if any.
    var label: String? {
        switch self {
        case .closeAll: "All"
        case .needsConfirmation(let appName): "\(appName ?? "The app") asks before closing"
        case .close, .minimize, .failed: nil
        }
    }

    /// A second, quieter line under the label.
    var detail: String? {
        guard case .needsConfirmation = self else { return nil }
        return "Click to review"
    }

    /// What VoiceOver says when the badge appears; nil for badges that follow the pointer.
    var announcement: String? {
        guard case .needsConfirmation(let appName) = self else { return nil }
        return "\(appName ?? "The app") asks before closing the window."
    }
}

/// Shows a traffic-light style badge on the thumbnail under the cursor while the
/// left-click trigger modifier is held in Mission Control, so it's clear which window
/// a click will act on and what it will do.
@MainActor
final class HoverBadgeController {
    static let shared = HoverBadgeController()
    private init() {}

    /// Distance of the badge centre from the thumbnail's top-left corner.
    private static let cornerInset: CGFloat = 10
    /// Circle centre measured from the badge view's top-left (padding + radius).
    private static let circleCentre = HoverBadgeView.padding + HoverBadgeView.diameter / 2
    private static let pollInterval: TimeInterval = 1.0 / 30
    /// While the pointer rests, hit-test again this often anyway: Mission Control re-lays out
    /// its thumbnails when a window opens or closes.
    private static let refreshInterval: Duration = .milliseconds(300)

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HoverBadgeView>?
    /// How long a failure badge stays before fading out.
    private static let failureDuration: Duration = .milliseconds(900)
    private var timer: Timer?
    private var flags: CGEventFlags = []
    /// Thumbnail the badge is currently on; a different one gets a fresh fade-in.
    private var currentThumbnail: CGRect?
    private var currentStyle: HoverBadgeStyle?
    /// Where the pointer was at the last hit-test, and when that was.
    private var lastPointer: CGPoint?
    private var lastResolve: ContinuousClock.Instant?

    /// Called from the event tap on every modifier change. Cheap: hit-testing waits for the
    /// timer, which fires once the callback has returned.
    func modifiersChanged(_ flags: CGEventFlags) {
        self.flags = flags
        guard isTriggerHeld, MissionControlSession.isActive() else {
            stop()
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
                MainActor.assumeIsolated { HoverBadgeController.shared.update() }
            }
            // Common modes keep the badge tracking while other run loop modes are active.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        // Show or restyle the badge right away rather than on the next tick.
        timer?.fireDate = .now
    }

    /// A window was closed or minimized: thumbnails move, so hit-test again on the next tick.
    func layoutMayHaveChanged() {
        lastResolve = nil
    }

    private var isTriggerHeld: Bool {
        let settings = SettingsStore.shared.current
        guard settings.showHoverBadge, let mask = settings.leftClickModifier?.eventFlagMask else { return false }
        return flags.contains(mask)
    }

    private func update() {
        guard isTriggerHeld,
              !MissionControlContextMenu.isOpen,
              MissionControlSession.isActive() else {
            stop()
            return
        }
        let style = HoverBadgeStyle(flags: flags)
        let pointer = NSEvent.mouseLocation
        let resolvedRecently = lastResolve.map { ContinuousClock.now - $0 < Self.refreshInterval } ?? false
        let onSameThumbnail = pointer == lastPointer
            || currentThumbnail.flatMap(MissionControlHitTester.thumbnailHitArea)?.contains(pointer) == true
        if resolvedRecently, onSameThumbnail {
            // Not moved, or still on the same thumbnail: no new hit-test needed.
            if let currentThumbnail, style != currentStyle {
                show(style: style, at: currentThumbnail)
            }
            return
        }
        lastPointer = pointer
        lastResolve = .now
        guard let frame = MissionControlHitTester.resolve(clickPoint: pointer)?.thumbnailFrame else {
            hide()
            return
        }
        show(style: style, at: frame)
    }

    private func show(style: HoverBadgeStyle, at thumbnail: CGRect) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        currentStyle = style
        let view = HoverBadgeView(style: style)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            panel.contentView = hostingView
            self.hostingView = hostingView
        }

        let badgeFrame = Self.badgeFrame(size: hostingView?.fittingSize ?? .zero, on: thumbnail)
        guard thumbnail != currentThumbnail else {
            // Same window, maybe another style (the "All" label changes the width).
            panel.setFrame(badgeFrame, display: true)
            return
        }
        currentThumbnail = thumbnail

        // Moving to another window: hide on the old one and fade in on the new one,
        // rather than sliding the badge across.
        panel.orderOut(nil)
        panel.alphaValue = 0
        panel.setFrame(badgeFrame, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// A plain fade-in; also what Reduce Motion gets instead of a pulse or shake.
    static func fadeIn() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.2
        return animation
    }

    /// Short side-to-side shake, kept within the badge's padding so the panel needn't grow.
    private static func shake() -> CAKeyframeAnimation {
        let amplitude = HoverBadgeView.padding
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -amplitude, amplitude, -amplitude, amplitude, -amplitude / 2, amplitude / 2, 0]
        animation.duration = 0.4
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }

    // MARK: - Failure

    /// Shakes the hover badge while it shows, else puts a grey × badge on each anchor: a
    /// thumbnail, or a point where the thumbnail isn't known. With Reduce Motion the × badge
    /// only fades. False when there was nowhere to show anything.
    func showFailure(at anchors: [CGRect]) -> Bool {
        if !ActionFeedback.reduceMotion, let panel, panel.isVisible, let hostingView {
            hostingView.wantsLayer = true
            hostingView.layer?.add(Self.shake(), forKey: "shake")
            return true
        }
        for anchor in anchors {
            showFailureBadge(at: anchor)
        }
        return !anchors.isEmpty
    }

    private func showFailureBadge(at anchor: CGRect) {
        let panel = Self.makePanel()
        let hostingView = NSHostingView(rootView: HoverBadgeView(style: .failed))
        hostingView.wantsLayer = true
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        let frame = anchor.isEmpty
            ? NSRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
            : Self.badgeFrame(size: size, on: anchor)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        hostingView.layer?.add(Self.fadeIn(), forKey: "fade")
        if !ActionFeedback.reduceMotion {
            hostingView.layer?.add(Self.shake(), forKey: "shake")
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.failureDuration)
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            panel.orderOut(nil)
        }
    }

    /// Hides the confirmation badges, e.g. when input is about to close Mission Control.
    func dismissFlash() {
        ConfirmationBadges.shared.dismiss()
    }

    /// Circle centre sits just inside the thumbnail's top-left corner, like a window's close button.
    static func badgeFrame(size: CGSize, on thumbnail: CGRect) -> NSRect {
        let origin = NSPoint(
            x: thumbnail.minX + cornerInset - circleCentre,
            y: thumbnail.maxY - cornerInset - size.height + circleCentre
        )
        return NSRect(origin: origin, size: size)
    }

    private func hide() {
        currentThumbnail = nil
        currentStyle = nil
        panel?.orderOut(nil)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        lastPointer = nil
        lastResolve = nil
        hide()
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // One above pop-up menus so it shows over Mission Control, and so the context
        // menu's own window lookup (which matches the menu level exactly) ignores it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }
}

/// Traffic-light circle with the action's glyph; close-all and confirmation badges add a label.
struct HoverBadgeView: View {
    static let diameter: CGFloat = 22
    /// Room around the circle for its shadow.
    static let padding: CGFloat = 4

    let style: HoverBadgeStyle
    /// Increase Contrast (System Settings › Accessibility › Display) draws stronger edges.
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color.gradient)
                .overlay(
                    Image(systemName: glyph)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black.opacity(highContrast ? 0.85 : 0.55))
                )
                .overlay(Circle().strokeBorder(.black.opacity(highContrast ? 0.7 : 0.18), lineWidth: highContrast ? 1 : 0.5))
                .frame(width: Self.diameter, height: Self.diameter)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            if let label = style.label {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                    if let detail = style.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(highContrast ? 0.6 : 0), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
        .padding(Self.padding)
    }

    private var highContrast: Bool {
        contrast == .increased
    }

    private var glyph: String {
        switch style {
        case .minimize: "minus"
        case .needsConfirmation: "questionmark"
        case .close, .closeAll, .failed: "xmark"
        }
    }

    /// System colours, so Increase Contrast and the accessibility colour filters apply.
    private var color: Color {
        switch style {
        case .minimize: Color(nsColor: .systemYellow)
        case .needsConfirmation: Color(nsColor: .systemOrange)
        case .close, .closeAll: Color(nsColor: .systemRed)
        case .failed: Color(nsColor: .systemGray)
        }
    }
}
