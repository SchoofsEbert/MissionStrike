import AppKit
import SwiftUI

/// What the event tap needs to know about Snap Assist.
enum SnapAssistPhase: Sendable {
    case idle
    /// A snap is on its way and may bring a picker: input meanwhile cancels it.
    case pending
    case showing
}

/// After a window snaps to a side, offers the other windows for the rest of the screen, like
/// Windows' Snap Assist: press a number or click one to place it, anything else closes it.
///
/// The cards are drawn on a click-through canvas; the event tap routes keys and clicks here
/// from `phase` and cached frames, without asking any app.
@MainActor
final class SnapAssist {
    static let shared = SnapAssist()
    private init() {}

    private struct Session {
        let action: SnapAction
        /// Where the picked window goes, in AX space.
        let target: CGRect
        /// The whole visible area of that screen, in AX space, which the picked window stays in.
        let screenArea: CGRect
        let screen: CGRect
        var candidates: [SnapCandidate]
        let icons: [pid_t: NSImage]
        var previews: [CGWindowID: CGImage] = [:]
        /// Canvas coordinates of `screen`.
        let panel: CGRect
        var cards: [CGRect]
        var hovered: Int?
    }

    private let canvas = OverlayCanvas()
    private var session: Session?
    private var isPending = false
    /// Bumped by every snap and every dismissal, so a picker that arrives late doesn't show.
    private var generation = 0
    /// Installed with the first snap and kept: they also cancel a picker still on its way.
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    /// Read by the event tap.
    var phase: SnapAssistPhase {
        session != nil ? .showing : isPending ? .pending : .idle
    }

    /// A snap is on its way; returns its token for `show`. A picker already up stays until the
    /// new one replaces it, so cycling doesn't flicker, but no longer picks.
    func snapStarted() -> Int {
        installObservers()
        generation += 1
        isPending = true
        return generation
    }

    /// Shows the picker over `target` (AX space), unless something happened since the snap.
    func show(action: SnapAction, target: CGRect?, screenArea: CGRect, candidates: [SnapCandidate], generation: Int) {
        guard generation == self.generation else { return }
        isPending = false
        guard let target, !candidates.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(ScreenCoordinates.yFlipped(target)) }) else {
            dismiss()
            return
        }
        let panel = OverlayCanvas.local(ScreenCoordinates.yFlipped(target), in: screen.frame)
        var icons: [pid_t: NSImage] = [:]
        for pid in Set(candidates.map(\.pid)) {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
        session = Session(
            action: action,
            target: target,
            screenArea: screenArea,
            screen: screen.frame,
            candidates: candidates,
            icons: icons,
            panel: panel,
            cards: SnapAssistModel.cardFrames(count: candidates.count, in: panel),
            hovered: nil
        )
        startTrackingPointer()
        render(on: screen)
        WindowSnapper.shared.loadDetails(for: candidates, generation: generation)
        if SettingsStore.shared.current.showSnapPreviews {
            let windowIDs = candidates.map(\.windowID)
            Task.detached(priority: .userInitiated) {
                guard SnapPreviews.isAllowed else { return }
                let previews = await SnapPreviews.capture(windowIDs)
                await SnapAssist.shared.previewsLoaded(previews, generation: generation)
            }
        }
    }

    /// The pictures arrived; they fade in over the icons.
    func previewsLoaded(_ previews: [CGWindowID: CGImage], generation: Int) {
        guard generation == self.generation, var session, !previews.isEmpty else { return }
        session.previews = previews
        self.session = session
        render()
    }

    /// Accessibility answered: titles, and which windows can't be placed after all (sheets,
    /// panels and full-screen windows on another display), which leave the picker.
    func detailsLoaded(_ details: SnapCandidateDetails, generation: Int) {
        guard generation == self.generation, var session else { return }
        session.candidates = session.candidates.compactMap { candidate in
            guard details.answered.contains(candidate.pid) else { return candidate }
            guard let title = details.titles[candidate.windowID] else { return nil }
            var candidate = candidate
            candidate.title = title.isEmpty ? nil : title
            return candidate
        }
        guard !session.candidates.isEmpty else {
            dismiss()
            return
        }
        session.cards = SnapAssistModel.cardFrames(count: session.candidates.count, in: session.panel)
        self.session = session
        render()
    }

    func handle(_ input: SnapAssistInput) {
        guard let session else {
            dismiss()
            return
        }
        switch input {
        case .pick(let index):
            // A newer snap is on its way: this picker's area is about to change.
            guard !isPending, session.candidates.indices.contains(index) else { return }
            let candidate = session.candidates[index]
            dismiss()
            WindowSnapper.shared.place(
                candidate,
                in: session.target,
                hugging: SnapAssistModel.opposite(of: session.action),
                within: session.screenArea
            )
        case .cancel, .dismiss:
            dismiss()
        }
    }

    func dismiss() {
        generation += 1
        isPending = false
        guard session != nil else { return }
        session = nil
        canvas.hide()
        stopTrackingPointer()
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
            icons: session.icons,
            previews: session.previews,
            panel: session.panel,
            cards: session.cards,
            hovered: session.hovered
        )
        canvas.show(on: [screen]) { _ in view }
    }

    // MARK: - Closing on its own

    private func installObservers() {
        guard observers.isEmpty else { return }
        let dismiss: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                if SnapAssist.shared.phase != .idle { SnapAssist.shared.dismiss() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map {
            workspace.addObserver(forName: $0, object: nil, queue: .main, using: dismiss)
        }
        // The session's coordinates are for the screens as they were.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: dismiss
        ))
    }

    /// Only while the picker shows: the cards light up under the pointer.
    private func startTrackingPointer() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { SnapAssist.shared.pointerMoved() }
        }
    }

    private func stopTrackingPointer() {
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

/// The picker: the free part of the screen outlined like macOS's own tiling preview, with the
/// windows laid out in it like App Exposé.
struct SnapAssistView: View {
    let candidates: [SnapCandidate]
    let icons: [pid_t: NSImage]
    let previews: [CGWindowID: CGImage]
    let panel: CGRect
    let cards: [CGRect]
    let hovered: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            SnapAreaOutline()
                .placed(in: panel.insetBy(dx: 6, dy: 6), alignment: .center)

            ForEach(Array(zip(candidates.indices, cards)), id: \.0) { index, cell in
                let candidate = candidates[index]
                SnapThumbnailView(
                    candidate: candidate,
                    icon: icons[candidate.pid],
                    preview: previews[candidate.windowID],
                    number: index + 1,
                    isHovered: hovered == index,
                    cell: cell.size
                )
                .placed(in: cell, alignment: .topLeading)
            }
        }
        .animation(.easeOut(duration: 0.15), value: previews.count)
    }
}

/// Like the outline macOS draws where a dragged window will tile: glass on macOS 26 and later.
private struct SnapAreaOutline: View {
    private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.clear, in: Self.shape)
                .overlay(Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
        } else {
            Self.shape
                .fill(.ultraThinMaterial)
                .overlay(Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
    }
}

/// One window: its picture (or its app's icon), a number to type, and its title below, with
/// Mission Control's blue ring under the pointer.
struct SnapThumbnailView: View {
    let candidate: SnapCandidate
    let icon: NSImage?
    let preview: CGImage?
    let number: Int
    let isHovered: Bool
    let cell: CGSize

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let thumbnail = SnapAssistModel.thumbnailFrame(for: candidate.size, in: cell)
        ZStack(alignment: .topLeading) {
            picture
                .frame(width: thumbnail.width, height: thumbnail.height)
                .clipShape(Self.shape)
                .overlay {
                    if isHovered {
                        Self.shape.inset(by: -4).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .overlay(alignment: .topLeading) {
                    NumberBadge(number: number)
                        .offset(x: -9, y: -9)
                }
                .offset(x: thumbnail.minX, y: thumbnail.minY)

            label
                .frame(width: cell.width)
                .offset(y: thumbnail.maxY + 8)
        }
        .frame(width: cell.width, height: cell.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var picture: some View {
        if let preview {
            Image(decorative: preview, scale: 2)
                .resizable()
                .transition(.opacity)
        } else {
            ZStack {
                Self.shape.fill(.regularMaterial)
                Image(nsImage: icon ?? NSWorkspace.shared.icon(for: .application))
                    .resizable()
                    .frame(width: 64, height: 64)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if preview != nil, let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(candidate.title ?? candidate.appName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: cell.width - 8)
    }
}

/// The number to type, on glass like the system's own small controls.
private struct NumberBadge: View {
    let number: Int

    var body: some View {
        let text = Text("\(number)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(width: 26, height: 26)
        if #available(macOS 26, *) {
            text.glassEffect(.regular, in: Circle())
        } else {
            text
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
    }
}
