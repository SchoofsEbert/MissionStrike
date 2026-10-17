import AppKit
import SwiftUI

/// Click-through panels covering whole screens above Mission Control, at the hover badge's
/// level, for overlays laid out in screen coordinates. Accessibility hit-testing looks through
/// windows that ignore the mouse, so a canvas never gets in the way of resolving a click.
@MainActor
final class OverlayCanvas {
    private struct Entry {
        let screen: CGRect
        let panel: NSPanel
        let host: NSHostingView<AnyView>
    }

    private var entries: [Entry] = []

    var isVisible: Bool {
        entries.contains { $0.panel.isVisible }
    }

    /// Draws `content` on each of `screens`, fading in the screens that weren't showing yet.
    /// The content fills its screen; lay it out with `local(_:in:)`.
    func show<Content: View>(on screens: [NSScreen] = NSScreen.screens, @ViewBuilder content: (NSScreen) -> Content) {
        let frames = screens.map(\.frame)
        for entry in entries where !frames.contains(entry.screen) {
            entry.panel.orderOut(nil)
        }
        entries.removeAll { !frames.contains($0.screen) }

        for screen in screens {
            let entry = entries.first { $0.screen == screen.frame } ?? makeEntry(for: screen.frame)
            entry.host.rootView = AnyView(
                content(screen)
                    .frame(width: screen.frame.width, height: screen.frame.height, alignment: .topLeading)
            )
            guard !entry.panel.isVisible else { continue }
            entry.panel.alphaValue = 0
            entry.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                entry.panel.animator().alphaValue = 1
            }
        }
    }

    /// Hides at once; the panels are kept for the next time. Cheap when nothing shows, as on
    /// every key press that dismisses the overlays.
    func hide() {
        for entry in entries where entry.panel.isVisible {
            entry.panel.orderOut(nil)
        }
    }

    private func makeEntry(for screen: CGRect) -> Entry {
        let panel = Self.makePanel()
        panel.setFrame(screen, display: false)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        // The panel's size comes from the screen, never from the content.
        host.sizingOptions = []
        panel.contentView = host
        let entry = Entry(screen: screen, panel: panel, host: host)
        entries.append(entry)
        return entry
    }

    /// A rect in AppKit screen coordinates, relative to a screen's top-left corner as SwiftUI
    /// lays out a canvas.
    static func local(_ rect: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The bottom half of a screen, above the Dock, in canvas coordinates: for tips aligned
    /// to its bottom edge.
    static func bottomArea(in screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let area = CGRect(x: visible.minX, y: visible.minY + 32, width: visible.width, height: visible.height / 2)
        return local(area, in: screen.frame)
    }

    /// The screen showing the pointer, where a card or tip is drawn.
    static var pointerScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    /// Like the hover badge's panel: one above pop-up menus, so it shows over Mission Control
    /// and the context menu's own window lookup (which matches the menu level exactly) ignores it.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
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

extension View {
    /// Places the view inside `rect` (canvas coordinates from `OverlayCanvas.local`), aligned
    /// within it, without having to know the view's size.
    func placed(in rect: CGRect, alignment: Alignment) -> some View {
        frame(width: rect.width, height: rect.height, alignment: alignment)
            .offset(x: rect.minX, y: rect.minY)
    }
}
