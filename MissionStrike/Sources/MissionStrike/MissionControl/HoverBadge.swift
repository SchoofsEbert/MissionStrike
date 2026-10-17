import AppKit
import QuartzCore
import SwiftUI

/// What a modifier-click would do to the hovered thumbnail, shown as a traffic-light badge.
enum HoverBadgeStyle: Equatable {
    case close
    case minimize
    case closeAll
    /// Flashed after a close when the app put up a sheet (unsaved changes, running processes).
    case needsConfirmation

    init(flags: CGEventFlags) {
        switch MouseAction(flags: flags) {
        case .close: self = .close
        case .minimize: self = .minimize
        case .closeAll: self = .closeAll
        }
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
    /// Separate from the hover badge so holding the trigger modifier doesn't cut a flash short.
    private var flashPanel: NSPanel?
    private var flashGeneration = 0
    private static let flashPulses = 3
    private static let flashPulseDuration: TimeInterval = 0.35
    private static let flashCheckInterval: Duration = .milliseconds(250)
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

    /// Shows a badge in the middle of a thumbnail, pulsing a few times to draw the eye. It stays
    /// while `isPending` holds and Mission Control is open, and Mission Control is never left.
    func flash(_ style: HoverBadgeStyle, on thumbnail: CGRect, while isPending: @escaping @MainActor () -> Bool) {
        let panel = flashPanel ?? Self.makePanel()
        flashPanel = panel
        let hostingView = NSHostingView(rootView: HoverBadgeView(style: style))
        hostingView.wantsLayer = true
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        panel.setFrame(NSRect(x: thumbnail.midX - size.width / 2, y: thumbnail.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        hostingView.layer?.add(Self.pulse(), forKey: "pulse")
        panel.orderFrontRegardless()

        flashGeneration += 1
        let generation = flashGeneration
        Task { @MainActor in
            // Input that closes Mission Control hides the badge straight away (`dismissFlash`);
            // this catches the rest, like the sheet being answered behind Mission Control.
            while generation == flashGeneration {
                try? await Task.sleep(for: Self.flashCheckInterval)
                guard generation == flashGeneration else { return }
                guard MissionControlSession.isActive(), isPending() else { break }
            }
            guard generation == flashGeneration else { return }
            hideFlash()
        }
    }

    /// Fades in, alternates dim and bright for the first pulses, then holds bright.
    private static func pulse() -> CAKeyframeAnimation {
        let values: [Float] = [0, 1] + Array(repeating: [0.35, 1], count: flashPulses).flatMap { $0 }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.duration = flashPulseDuration * Double(values.count - 1)
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: values.count - 1
        )
        return animation
    }

    /// Hides the confirmation badge, e.g. when input is about to close Mission Control.
    func dismissFlash() {
        guard flashPanel?.isVisible == true else { return }
        flashGeneration += 1
        hideFlash()
    }

    private func hideFlash() {
        flashPanel?.alphaValue = 0
        flashPanel?.orderOut(nil)
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

    private static func makePanel() -> NSPanel {
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

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color.gradient)
                .overlay(
                    Image(systemName: glyph)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: Self.diameter, height: Self.diameter)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
        .padding(Self.padding)
    }

    private var glyph: String {
        switch style {
        case .minimize: "minus"
        case .needsConfirmation: "exclamationmark"
        case .close, .closeAll: "xmark"
        }
    }

    private var label: String? {
        switch style {
        case .closeAll: "All"
        case .needsConfirmation: "Needs Confirmation"
        case .close, .minimize: nil
        }
    }

    private var color: Color {
        switch style {
        case .minimize, .needsConfirmation: Color(red: 1.0, green: 0.74, blue: 0.18)
        case .close, .closeAll: Color(red: 1.0, green: 0.37, blue: 0.34)
        }
    }
}
