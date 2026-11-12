import AppKit
import SwiftUI

/// After a window snaps to a side, offers the other windows for the rest of the screen, like
/// Windows' Snap Assist: press a number or click one to place it, anything else closes it.
///
/// The cards are drawn on a click-through canvas; the event tap routes keys and clicks here
/// while `isActive`, from cached frames, without asking any app.
@MainActor
final class SnapAssist {
    static let shared = SnapAssist()
    private init() {}

    private struct Session {
        let action: SnapAction
        /// Where the picked window goes, in AX space.
        let area: CGRect
        let screen: CGRect
        var candidates: [SnapCandidate]
        /// Canvas coordinates of `screen`.
        let panel: CGRect
        let cards: [CGRect]
        var hovered: Int?
    }

    private let canvas = OverlayCanvas()
    private var session: Session?
    /// Bumped by every snap and every dismissal, so a picker that arrives late doesn't show.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    /// Read by the event tap.
    var isActive: Bool { session != nil }

    /// A snap is on its way; returns its token for `show`.
    func snapStarted() -> Int {
        generation += 1
        return generation
    }

    /// Shows the picker over `area` (AX space), unless something happened since the snap.
    func show(action: SnapAction, area: CGRect, candidates: [SnapCandidate], generation: Int) {
        guard generation == self.generation else { return }
        guard !candidates.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(ScreenCoordinates.yFlipped(area)) }) else {
            dismiss()
            return
        }
        let panel = OverlayCanvas.local(ScreenCoordinates.yFlipped(area), in: screen.frame)
        session = Session(
            action: action,
            area: area,
            screen: screen.frame,
            candidates: candidates,
            panel: panel,
            cards: SnapAssistModel.cardFrames(count: candidates.count, in: panel),
            hovered: nil
        )
        startObserving()
        render(on: screen)
        WindowSnapper.shared.loadTitles(for: candidates, generation: generation)
    }

    /// Titles arrived from Accessibility.
    func titlesLoaded(_ titles: [CGWindowID: String], generation: Int) {
        guard generation == self.generation, var session else { return }
        for index in session.candidates.indices {
            session.candidates[index].title = titles[session.candidates[index].windowID]
        }
        self.session = session
        render()
    }

    func handle(_ input: SnapAssistInput) {
        guard let session else { return }
        switch input {
        case .pick(let index):
            guard session.candidates.indices.contains(index) else { return }
            let candidate = session.candidates[index]
            dismiss()
            WindowSnapper.shared.place(
                candidate,
                in: session.area,
                hugging: SnapAssistModel.opposite(of: session.action)
            )
        case .cancel, .dismiss:
            dismiss()
        }
    }

    func dismiss() {
        generation += 1
        guard session != nil else { return }
        session = nil
        canvas.hide()
        stopObserving()
    }

    // MARK: - Hit-testing for the event tap

    /// The card under a point in AppKit screen space.
    func card(at point: CGPoint) -> Int? {
        guard let session else { return nil }
        let local = Self.local(point, in: session.screen)
        return session.cards.firstIndex { $0.contains(local) }
    }

    func contains(_ point: CGPoint) -> Bool {
        guard let session else { return false }
        return session.panel.contains(Self.local(point, in: session.screen))
    }

    private static func local(_ point: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
    }

    // MARK: - Drawing

    private func render(on screen: NSScreen? = nil) {
        guard let session,
              let screen = screen ?? NSScreen.screens.first(where: { $0.frame == session.screen }) else { return }
        let view = SnapAssistView(
            candidates: session.candidates,
            panel: session.panel,
            cards: session.cards,
            hovered: session.hovered
        )
        canvas.show(on: [screen]) { _ in view }
    }

    // MARK: - Closing on its own

    private func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SnapAssist.shared.dismiss() }
            }
        }
        // Only while the picker shows: the cards light up under the pointer.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { SnapAssist.shared.pointerMoved() }
        }
    }

    private func stopObserving() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func pointerMoved() {
        guard var session else { return }
        let hovered = card(at: NSEvent.mouseLocation)
        guard hovered != session.hovered else { return }
        session.hovered = hovered
        self.session = session
        render()
    }
}

/// The picker: a dimmed panel over the free part of the screen, with a card per window.
struct SnapAssistView: View {
    let candidates: [SnapCandidate]
    let panel: CGRect
    let cards: [CGRect]
    let hovered: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.15)))
                .padding(8)
                .placed(in: panel, alignment: .center)

            VStack(spacing: 2) {
                Text("Choose a window for this side")
                    .font(.system(size: 15, weight: .semibold))
                Text(candidates.count == 1 ? "Press 1 or click it · Esc to close" : "Press 1–\(candidates.count) or click one · Esc to close")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .placed(in: header, alignment: .bottom)

            ForEach(Array(zip(candidates.indices, cards)), id: \.0) { index, frame in
                SnapCardView(candidate: candidates[index], number: index + 1, isHovered: hovered == index)
                    .placed(in: frame, alignment: .center)
            }
        }
    }

    /// Just above the cards, which sit in the middle of the panel.
    private var header: CGRect {
        let top = cards.first?.minY ?? panel.midY
        return CGRect(x: panel.minX, y: top - SnapAssistModel.headerHeight - 4, width: panel.width, height: SnapAssistModel.headerHeight)
    }
}

/// One window: its number like a keycap, the app's icon and name, and the title once known.
struct SnapCardView: View {
    let candidate: SnapCandidate
    let number: Int
    let isHovered: Bool

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                Text("\(number)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .frame(minWidth: 14)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer()
            }
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(spacing: 1) {
                Text(candidate.appName)
                    .font(.system(size: 13, weight: .semibold))
                Text(candidate.title ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.shape.fill(.regularMaterial))
        .overlay(Self.shape.strokeBorder(isHovered ? Color.accentColor : .white.opacity(0.2), lineWidth: isHovered ? 3 : 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    private var icon: NSImage {
        NSRunningApplication(processIdentifier: candidate.pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
    }
}
