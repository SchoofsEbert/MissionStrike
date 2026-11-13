import AppKit
import SwiftUI

/// What the event tap needs to know about Snap Assist.
enum SnapAssistPhase: Sendable {
    case idle
    /// A picker is on its way and none shows yet: numbers and Esc wait for it, anything else
    /// cancels it.
    case pending
    /// A picker is on screen (maybe about to be replaced by the next cycling step).
    case showing
}

/// After a window snaps to a side, offers the other windows for the rest of the screen, like
/// Windows' Snap Assist: press a number, or move with the arrows and press Return, or click one
/// to place it; anything else closes it.
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
        var backdrop: Backdrop = .loading
        /// Accessibility has said which windows can be placed.
        var hasDetails = false
        /// Canvas coordinates of `screen`.
        let panel: CGRect
        var cards: [CGRect] = []
        /// Under the pointer or chosen with the arrows: one ring for both.
        var selected: Int?
    }

    /// The wallpaper the windows are drawn on, like Mission Control's.
    enum Backdrop {
        case loading
        case image(CGImage)
        /// None to be had: the glass outline instead.
        case unavailable
    }

    /// How long a picker waits for Accessibility to say which windows can be placed, and for
    /// the wallpaper, before it shows anyway; after it shows, the numbers never change.
    private static let detailsWait: Duration = .milliseconds(120)

    private let canvas = OverlayCanvas()
    /// On screen.
    private var visible: Session?
    /// Being prepared; replaces `visible` once ready.
    private var upcoming: Session?
    /// A snap is on its way and hasn't handed over its windows yet.
    private var isPending = false
    /// A pick made before its picker showed: by number, or by window when made on the last
    /// picker while cycling, so it can't shift with the numbers.
    private struct QueuedPick {
        let index: Int
        let windowID: CGWindowID?
    }
    private var queuedPick: QueuedPick?
    /// Keys held back while no picker shows, given back in order if none comes.
    private var heldKeys: [CGEvent] = []
    /// Bumped by every snap and every dismissal, so a picker that arrives late doesn't show.
    private var generation = 0
    private var previewTask: Task<Void, Never>?
    /// Installed with the first snap and kept: they also cancel a picker still on its way.
    var observers: [NSObjectProtocol] = []
    var mouseMonitor: Any?

    /// Read by the event tap: a key that would only close the coming picker waits behind these.
    var holdsKeys: Bool { !heldKeys.isEmpty }

    /// Read by the event tap.
    var phase: SnapAssistPhase {
        if visible != nil { return .showing }
        return isPending || upcoming != nil ? .pending : .idle
    }

    /// A snap is on its way; returns its token for `show`. A picker already up stays until the
    /// next one replaces it, so cycling doesn't flicker.
    func snapStarted() -> Int {
        installObservers()
        generation += 1
        isPending = true
        upcoming = nil
        previewTask?.cancel()
        return generation
    }

    /// Prepares the picker over `target` (AX space), unless something happened since the snap.
    /// It shows once Accessibility has weeded out windows that can't be placed and the wallpaper
    /// is in, or after `detailsWait`, whichever comes first.
    func show(action: SnapAction, target: CGRect?, screenArea: CGRect, candidates: [SnapCandidate], generation: Int) {
        guard generation == self.generation else { return }
        isPending = false
        guard let target, !candidates.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(ScreenCoordinates.yFlipped(target)) }) else {
            dismiss()
            return
        }
        // Cycling to the next step keeps what the last picker already knew.
        let previous = visible
        let known = Dictionary(previous?.candidates.map { ($0.windowID, $0.title) } ?? [], uniquingKeysWith: { first, _ in first })
        var icons = previous?.icons ?? [:]
        for pid in Set(candidates.map(\.pid)) where icons[pid] == nil {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
        upcoming = Session(
            action: action,
            target: target,
            screenArea: screenArea,
            screen: screen.frame,
            candidates: candidates.map { candidate in
                var candidate = candidate
                candidate.title = known[candidate.windowID].flatMap { $0 }
                return candidate
            },
            icons: icons,
            previews: previous?.previews ?? [:],
            panel: OverlayCanvas.local(ScreenCoordinates.yFlipped(target), in: screen.frame)
        )
        WindowSnapper.shared.loadDetails(for: candidates, generation: generation)
        Task { @MainActor in
            try? await Task.sleep(for: Self.detailsWait)
            self.reveal(generation: generation)
        }
        loadPictures(
            // Only those likely to be shown: one per number key.
            of: candidates.prefix(SnapAssistModel.maxCandidates).map(\.windowID),
            backdrop: SnapBackdrop.request(region: target, on: screen),
            generation: generation
        )
    }

    /// With previews on and Screen Recording allowed, the windows and the wallpaper as they show,
    /// in one go. Otherwise the wallpaper from its file, which captures nothing on screen.
    private func loadPictures(of windowIDs: [CGWindowID], backdrop: SnapBackdrop.Request, generation: Int) {
        let capturing = SettingsStore.shared.current.showSnapPreviews
        previewTask = Task.detached(priority: .userInitiated) {
            var pictures: (previews: [CGWindowID: CGImage], backdrop: CGImage?) = ([:], nil)
            var allowed = false
            if capturing {
                allowed = SnapPreviews.isAllowed
                await ScreenRecordingPermission.shared.report(allowed)
            }
            if allowed {
                pictures = await SnapPreviews.capture(windowIDs, backdrop: backdrop)
            }
            if pictures.backdrop == nil, !Task.isCancelled {
                pictures.backdrop = SnapBackdrop.decode(backdrop)
            }
            guard !Task.isCancelled else { return }
            await SnapAssist.shared.picturesLoaded(pictures.previews, backdrop: pictures.backdrop, generation: generation)
        }
    }

    /// Lays out the cards, at most one per number key, and puts them on screen in place of the
    /// last picker; then acts on a number typed while waiting.
    private func reveal(generation: Int) {
        guard generation == self.generation, var session = upcoming else { return }
        session.candidates = Array(session.candidates.prefix(SnapAssistModel.maxCandidates))
        session.cards = SnapAssistModel.cardFrames(count: session.candidates.count, in: session.panel)
        upcoming = nil
        heldKeys = []
        visible = session
        // A number typed while waiting picks at once, without drawing a picker for a moment.
        if let queued = queuedPick {
            queuedPick = nil
            let index = queued.windowID.flatMap { id in session.candidates.firstIndex { $0.windowID == id } } ?? queued.index
            handle(.pick(index))
            return
        }
        let pointed = card(at: NSEvent.mouseLocation)
        visible?.selected = pointed
        startTrackingPointer()
        render()
    }

    /// The pictures arrived; previews fade in over the icons.
    func picturesLoaded(_ previews: [CGWindowID: CGImage], backdrop: CGImage?, generation: Int) {
        guard generation == self.generation else { return }
        let backdrop = backdrop.map(Backdrop.image) ?? .unavailable
        if var session = upcoming {
            session.previews.merge(previews) { _, new in new }
            session.backdrop = backdrop
            upcoming = session
            if session.hasDetails {
                reveal(generation: generation)
            }
        } else if var session = visible {
            // Shown before its pictures came.
            session.previews.merge(previews) { _, new in new }
            session.backdrop = backdrop
            visible = session
            render()
        }
    }

    /// Accessibility answered: titles, and, before the picker shows, which windows can't be
    /// placed after all (sheets, panels and full-screen windows on another display). Once it
    /// shows, those stay: a pick on one does nothing, which beats renumbering under the user.
    func detailsLoaded(_ details: SnapCandidateDetails, generation: Int) {
        guard generation == self.generation else { return }
        if var session = upcoming {
            session.candidates = Self.applying(details, to: session.candidates, keepingUnplaceable: false)
            guard !session.candidates.isEmpty else {
                dismiss()
                return
            }
            session.hasDetails = true
            upcoming = session
            if case .loading = session.backdrop {
                // The wallpaper is still on its way; the wait shows the picker if it's slow.
            } else {
                reveal(generation: generation)
            }
        } else if var session = visible {
            session.candidates = Self.applying(details, to: session.candidates, keepingUnplaceable: true)
            visible = session
            render()
        }
    }

    private static func applying(
        _ details: SnapCandidateDetails,
        to candidates: [SnapCandidate],
        keepingUnplaceable: Bool
    ) -> [SnapCandidate] {
        candidates.compactMap { candidate in
            guard details.answered.contains(candidate.pid) else { return candidate }
            guard let title = details.titles[candidate.windowID] else { return keepingUnplaceable ? candidate : nil }
            var candidate = candidate
            candidate.title = title.isEmpty ? nil : title
            return candidate
        }
    }
}

// MARK: - Keys and clicks

extension SnapAssist {
    /// A key or click for the picker. `replay` is the key itself, held back while no picker
    /// shows and given back if none comes.
    func handle(_ input: SnapAssistInput, replay: CGEvent? = nil) {
        if upcoming != nil || isPending {
            handleWhileWaiting(input, replay: replay)
            return
        }
        guard let session = visible else {
            dismiss()
            return
        }
        switch input {
        case .pick(let index):
            guard session.candidates.indices.contains(index) else { return }
            let candidate = session.candidates[index]
            dismiss()
            WindowSnapper.shared.place(
                candidate,
                in: session.target,
                hugging: SnapAssistModel.opposite(of: session.action),
                within: session.screenArea
            )
        case .move(let direction):
            moveSelection(direction)
        case .confirm:
            if let selected = session.selected {
                handle(.pick(selected))
            }
        case .cancel, .dismiss, .giveBack:
            dismiss()
        }
    }

    /// Between pickers, or before the first: a number waits for the next one.
    private func handleWhileWaiting(_ input: SnapAssistInput, replay: CGEvent?) {
        switch input {
        case .pick(let index):
            if let visible {
                // Typed at the picker on screen: the same window in the next one.
                queuedPick = QueuedPick(index: index, windowID: visible.candidates[safe: index]?.windowID)
            } else {
                queuedPick = queuedPick ?? QueuedPick(index: index, windowID: nil)
                if let replay { heldKeys.append(replay) }
            }
        case .confirm:
            if let selected = visible?.selected {
                queuedPick = QueuedPick(index: selected, windowID: visible?.candidates[safe: selected]?.windowID)
            }
        case .move(let direction):
            moveSelection(direction)
        case .giveBack:
            if let replay { heldKeys.append(replay) }
            dismiss()
        case .cancel:
            dismiss(givingBackKeys: false)
        case .dismiss:
            dismiss()
        }
    }

    /// Only a card the pointer moves onto takes the ring: moving off one keeps the ring where the
    /// arrows may want it.
    func pointerMoved() {
        guard var session = visible, let pointed = card(at: NSEvent.mouseLocation), pointed != session.selected else { return }
        session.selected = pointed
        visible = session
        render()
    }

    private func moveSelection(_ direction: HintDirection) {
        guard var session = visible else { return }
        session.selected = SnapAssistModel.card(from: session.selected, moving: direction, in: session.cards)
        visible = session
        render()
    }

    /// Closes the picker and any on its way, giving back keys held for it unless they were for it
    /// (Esc). The windows go a moment later, outside the event tap's callback, and with them the
    /// pictures of other apps' windows.
    func dismiss(givingBackKeys: Bool = true) {
        generation += 1
        isPending = false
        previewTask?.cancel()
        previewTask = nil
        upcoming = nil
        queuedPick = nil
        if givingBackKeys {
            for key in heldKeys {
                key.setIntegerValueField(.eventSourceUserData, value: replayedEventMarker)
                key.post(tap: .cgSessionEventTap)
            }
        }
        heldKeys = []
        guard visible != nil else { return }
        visible = nil
        stopTrackingPointer()
        DispatchQueue.main.async { [canvas] in
            // Unless a new picker has taken the canvas since.
            if SnapAssist.shared.visible == nil {
                canvas.tearDown()
            }
        }
    }
}

// MARK: - Hit-testing for the event tap

extension SnapAssist {

    /// The card under a point in AppKit screen space.
    func card(at point: CGPoint) -> Int? {
        guard let session = visible else { return nil }
        let local = Self.local(point, in: session.screen)
        return session.cards.firstIndex { $0.contains(local) }
    }

    func contains(_ point: CGPoint) -> Bool {
        guard let session = visible else { return false }
        return session.panel.contains(Self.local(point, in: session.screen))
    }

    private static func local(_ point: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
    }

    // MARK: - Drawing

    private func render() {
        guard let session = visible,
              let screen = NSScreen.screens.first(where: { $0.frame == session.screen }) else { return }
        let view = SnapAssistView(
            candidates: session.candidates,
            icons: session.icons,
            previews: session.previews,
            backdrop: session.backdrop,
            expectsPreviews: SettingsStore.shared.current.showSnapPreviews && ScreenRecordingPermission.shared.isAllowed == true,
            panel: session.panel,
            cards: session.cards,
            selected: session.selected
        )
        canvas.show(on: [screen]) { _ in view }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
