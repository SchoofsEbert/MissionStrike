import AppKit
import SwiftUI

/// What a modifier-click would do to the hovered thumbnail, shown as a traffic-light badge.
enum HoverBadgeStyle: Equatable {
    case close
    case minimize
    case closeAll

    init(flags: CGEventFlags) {
        if flags.contains(.maskCommand) {
            self = .closeAll
        } else if flags.contains(.maskShift) {
            self = .minimize
        } else {
            self = .close
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
    private var timer: Timer?
    private var flags: CGEventFlags = []

    /// Called from the event tap on every modifier change.
    func modifiersChanged(_ flags: CGEventFlags) {
        self.flags = flags
        guard isTriggerHeld, MissionControlActiveChecker().isActive() else {
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
        let raw = UserDefaults.standard.string(forKey: "leftClickModifier") ?? "option"
        guard let mask = TriggerModifier(rawValue: raw)?.eventFlagMask else { return false }
        return flags.contains(mask)
    }

    private func update() {
        guard isTriggerHeld,
              !MissionControlContextMenu.isOpen,
              MissionControlActiveChecker().isActive() else {
            stop()
            return
        }
        guard let frame = MissionControlHitTester.resolve(clickPoint: NSEvent.mouseLocation)?.thumbnailFrame else {
            panel?.orderOut(nil)
            return
        }
        show(style: HoverBadgeStyle(flags: flags), at: frame)
    }

    private func show(style: HoverBadgeStyle, at thumbnail: CGRect) {
        let panel = self.panel ?? makePanel()
        let view = HoverBadgeView(style: style)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            panel.contentView = hostingView
            self.hostingView = hostingView
        }

        // Circle centre sits just inside the thumbnail's top-left corner, like a window's close button.
        let size = hostingView?.fittingSize ?? .zero
        let origin = NSPoint(
            x: thumbnail.minX + Self.cornerInset - Self.circleCentre,
            y: thumbnail.maxY - Self.cornerInset - size.height + Self.circleCentre
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
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
        self.panel = panel
        return panel
    }
}

/// Traffic-light circle with the action's glyph; "All" is added for close-all.
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
                    Image(systemName: style == .minimize ? "minus" : "xmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                )
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: Self.diameter, height: Self.diameter)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            if style == .closeAll {
                Text("All")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
        .padding(Self.padding)
    }

    private var color: Color {
        style == .minimize
            ? Color(red: 1.0, green: 0.74, blue: 0.18)
            : Color(red: 1.0, green: 0.37, blue: 0.34)
    }
}
