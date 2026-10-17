import AppKit
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

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HoverBadgeView>?
    /// Separate from the hover badge so holding the trigger modifier doesn't cut a flash short.
    private var flashPanel: NSPanel?
    private var flashGeneration = 0
    private static let flashPulses = 3
    private static let flashPulseDuration: TimeInterval = 0.35
    private static let flashFrameInterval: Duration = .milliseconds(16)
    private static let flashPendingCheckInterval: Duration = .milliseconds(300)
    private var timer: Timer?
    private var flags: CGEventFlags = []
    /// Thumbnail the badge is currently on; a different one gets a fresh fade-in.
    private var currentThumbnail: CGRect?

    /// Called from the event tap on every modifier change.
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
        update()
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
        guard let frame = MissionControlHitTester.resolve(clickPoint: NSEvent.mouseLocation)?.thumbnailFrame else {
            hide()
            return
        }
        show(style: HoverBadgeStyle(flags: flags), at: frame)
    }

    private func show(style: HoverBadgeStyle, at thumbnail: CGRect) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
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
        panel.contentView = hostingView
        let size = hostingView.fittingSize
        panel.setFrame(NSRect(x: thumbnail.midX - size.width / 2, y: thumbnail.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        flashGeneration += 1
        let generation = flashGeneration
        Task { @MainActor in
            let start = ContinuousClock.now
            var lastPendingCheck = start
            var dimmed: Bool?
            // Mission Control is checked every frame: its WindowManager overlays vanish as soon
            // as it starts closing, so the badge can fade out with Mission Control, not after it.
            while generation == flashGeneration, MissionControlSession.isActive() {
                let now = ContinuousClock.now
                if now - lastPendingCheck >= Self.flashPendingCheckInterval {
                    lastPendingCheck = now
                    guard isPending() else { break }
                }
                // Alternate bright and dim for the first pulses, then hold steady.
                let step = Int((now - start) / .seconds(Self.flashPulseDuration))
                let dim = step < Self.flashPulses * 2 && !step.isMultiple(of: 2)
                if dim != dimmed {
                    dimmed = dim
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = Self.flashPulseDuration
                        panel.animator().alphaValue = dim ? 0.35 : 1
                    }, completionHandler: nil)
                }
                try? await Task.sleep(for: Self.flashFrameInterval)
            }
            guard generation == flashGeneration else { return }
            hideFlash()
        }
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
    private static func badgeFrame(size: CGSize, on thumbnail: CGRect) -> NSRect {
        let origin = NSPoint(
            x: thumbnail.minX + cornerInset - circleCentre,
            y: thumbnail.maxY - cornerInset - size.height + circleCentre
        )
        return NSRect(origin: origin, size: size)
    }

    private func hide() {
        currentThumbnail = nil
        panel?.orderOut(nil)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
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
