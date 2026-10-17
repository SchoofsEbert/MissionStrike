import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Vimium-style keyboard hints in Mission Control: F puts a label on every window thumbnail
/// and Space, typing a label selects it, and a letter acts on it. `HintSession` has the grammar.
///
/// The event tap swallows every plain key press while `isActive`, deciding from that flag
/// alone. Actions go through `MissionControlManager`, so they look and feel like a click.
@MainActor
final class KeyboardHints {
    static let shared = KeyboardHints()
    private init() {}

    private enum Target {
        case window(MissionControlThumbnail)
        case space(MissionControlSpace)

        var frame: CGRect {
            switch self {
            case .window(let thumbnail): thumbnail.frame
            case .space(let space): space.frame
            }
        }
    }

    struct LegendItem: Equatable {
        let key: String?
        let text: String
    }

    /// Plenty for any Mission Control: every two-letter label.
    private static let maxTargets = HintLabels.alphabet.count * HintLabels.alphabet.count

    private let canvas = OverlayCanvas()
    /// Read by the event tap. True from the F press on, before the labels are up, so the keys
    /// typed right after F are not lost.
    private(set) var isActive = false
    private var session: HintSession?
    private var targets: [Target] = []
    /// Keys typed before the labels were up, with copies to post again if there's nothing to label.
    private var early: [(key: HintKey, isRepeat: Bool, event: CGEvent)] = []
    private var startEvent: CGEvent?
    private var generation = 0
    private var isRenderPending = false

    /// F was pressed and swallowed. Called from the tap callback: flips the flag and looks up
    /// the thumbnails in a task.
    func start(replay: CGEvent) {
        isActive = true
        generation += 1
        let generation = generation
        startEvent = replay
        early = []
        FirstRunHint.shared.hide()
        Task { @MainActor in
            let layout = await MissionControlThumbnails.shared.layout(maxAge: .milliseconds(500), includeSpaces: true)
            guard generation == self.generation else { return }
            let targets = Self.targets(in: layout, settings: SettingsStore.shared.current)
            guard !targets.isEmpty else {
                giveBackKeys()
                return
            }
            begin(with: targets)
        }
    }

    /// A key while hints are active. Called from the tap callback: the grammar is plain state,
    /// and actions wait for a task.
    func handle(_ key: HintKey, isRepeat: Bool, replay: CGEvent) {
        guard isActive else { return }
        guard var session else {
            if key == .cancel {
                cancel()
            } else {
                early.append((key, isRepeat, replay))
            }
            return
        }
        // A held key repeats; only moving the selection and deleting should.
        if isRepeat {
            switch key {
            case .move, .deleteBackward: break
            default: return
            }
        }
        let outcome = session.handle(key)
        self.session = session
        switch outcome {
        case .unchanged:
            break
        case .changed:
            setNeedsRender()
        case .exit:
            cancel()
        case .perform(let action, let index):
            let target = targets[index]
            cancel()
            Task { @MainActor in
                perform(action, on: target)
            }
        }
    }

    /// Ends hints: Esc, a click, a key hints don't take, or Mission Control closing.
    func cancel() {
        guard isActive else { return }
        isActive = false
        session = nil
        targets = []
        early = []
        startEvent = nil
        generation += 1
        canvas.hide()
    }

    // MARK: - Labels

    /// Windows first, so they get the single letters; then Spaces that can do something.
    private static func targets(in layout: MissionControlLayout, settings: Settings) -> [Target] {
        let windows = layout.thumbnails
        let windowOrder = HintLabels.readingOrder(windows.map(\.frame))
        let spaces = (layout.spaces ?? []).filter { !allowedActions(for: .space($0), settings: settings).isEmpty }
        let spaceOrder = HintLabels.readingOrder(spaces.map(\.frame))
        let targets = windowOrder.map { Target.window(windows[$0]) } + spaceOrder.map { Target.space(spaces[$0]) }
        return Array(targets.prefix(maxTargets))
    }

    private static func allowedActions(for target: Target, settings: Settings) -> Set<HintAction> {
        switch target {
        case .window:
            return Set(HintAction.allCases)
        case .space(let space):
            var actions: Set<HintAction> = []
            if settings.enableSpaceClosing { actions.insert(.close) }
            if space.canOpen { actions.insert(.open) }
            return actions
        }
    }

    private func begin(with targets: [Target]) {
        let settings = SettingsStore.shared.current
        self.targets = targets
        session = HintSession(
            frames: targets.map(\.frame),
            allowed: targets.map { Self.allowedActions(for: $0, settings: settings) }
        )
        startEvent = nil
        render()
        let early = early
        self.early = []
        for key in early where isActive {
            handle(key.key, isRepeat: key.isRepeat, replay: key.event)
        }
    }

    /// Nothing to label (before macOS 27, or no windows): F and what followed it go on as if
    /// they had never been swallowed, unless Mission Control has closed since.
    private func giveBackKeys() {
        let events = (startEvent.map { [$0] } ?? []) + early.map(\.event)
        cancel()
        guard MissionControlSession.isActive(maxAge: .zero) else { return }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: replayedEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Draws once the tap callback has returned, and once for any keys typed in the same burst.
    private func setNeedsRender() {
        guard !isRenderPending else { return }
        isRenderPending = true
        Task { @MainActor in
            isRenderPending = false
            render()
        }
    }

    private func render() {
        guard let session else { return }
        let hints = targets.indices.map { index in
            HintChip(
                label: session.labels[index],
                typed: session.typed,
                isMatch: session.matches(index),
                isSelected: session.selection == index,
                frame: targets[index].frame
            )
        }
        let legend = Self.legend(for: session.selection.map { session.allowed[$0] })
        let legendScreen = OverlayCanvas.pointerScreen?.frame
        canvas.show { screen in
            KeyboardHintsView(
                hints: hints.filter { NSMouseInRect(NSPoint(x: $0.frame.midX, y: $0.frame.midY), screen.frame, false) },
                screen: screen.frame,
                legend: screen.frame == legendScreen ? legend : nil,
                legendArea: OverlayCanvas.bottomArea(in: screen)
            )
        }
    }

    /// What the keys do now: how to pick before anything is selected, then the selection's actions.
    nonisolated static func legend(for allowed: Set<HintAction>?) -> [LegendItem] {
        guard let allowed else {
            return [LegendItem(key: nil, text: "Type a label to pick a window"), LegendItem(key: "esc", text: "Stop")]
        }
        let names: [(HintAction, String)] = [
            (.close, "Close"), (.minimize, "Minimize"), (.hide, "Hide"), (.quit, "Quit"), (.closeAll, "Close All"), (.open, "Open")
        ]
        let actions = names.filter { allowed.contains($0.0) }.map { action, name in
            LegendItem(key: action.letter.map { String($0).uppercased() } ?? "↩", text: name)
        }
        return actions + [LegendItem(key: "esc", text: "Stop")]
    }

    // MARK: - Actions

    private func perform(_ action: HintAction, on target: Target) {
        // Mission Control closed while the key waited: act on nothing the user can't see.
        guard MissionControlSession.isActive(maxAge: .zero) else { return }
        let manager = MissionControlManager.shared
        switch target {
        case .window(let thumbnail):
            let resolution = MissionControlHitTester.Resolution(
                target: .window(pid: thumbnail.window.pid, ownerName: thumbnail.window.ownerName, windowID: thumbnail.window.windowID),
                point: CGPoint(x: thumbnail.axFrame.midX, y: thumbnail.axFrame.midY),
                thumbnailFrame: thumbnail.frame
            )
            switch action {
            case .close: manager.perform(.closeWindow, on: resolution)
            case .minimize: manager.perform(.minimizeWindow, on: resolution)
            case .hide: manager.perform(.hideApp, on: resolution)
            case .quit: manager.perform(.quitApp, on: resolution)
            case .closeAll: manager.perform(resolution: resolution, action: .closeAll)
            case .open: open(thumbnail)
            }
            let centre = CGPoint(x: thumbnail.frame.midX, y: thumbnail.frame.midY)
            Diagnostics.shared.record("keyboard hint", at: centre, resolution: resolution)

        case .space(let space):
            switch action {
            case .close:
                manager.perform(.closeWindow, on: MissionControlHitTester.Resolution(
                    target: .removeDesktop(space.element),
                    point: CGPoint(x: space.axFrame.midX, y: space.axFrame.midY)
                ))
            case .open:
                space.element.perform(kAXPressAction)
            case .minimize, .hide, .quit, .closeAll:
                break
            }
        }
    }

    /// Presses the thumbnail, which is what clicking it does: Mission Control closes on that
    /// window. If WindowManager won't take the press, leave Mission Control and raise the window.
    private func open(_ thumbnail: MissionControlThumbnail) {
        guard thumbnail.element.perform(kAXPressAction) != .success else { return }
        let window = thumbnail.window
        Task { @MainActor in
            Self.postEscape()
            var checks = 0
            while checks < 20, MissionControlSession.isActive(maxAge: .zero) {
                try? await Task.sleep(for: .milliseconds(50))
                checks += 1
            }
            let app = AXElement.application(window.pid)
            guard let axWindow = app.windows?.first(where: { $0.windowID == window.windowID }) else { return }
            axWindow.perform(kAXRaiseAction)
            axWindow.set(kAXMainAttribute, to: kCFBooleanTrue)
            app.set(kAXFrontmostAttribute, to: kCFBooleanTrue)
        }
    }

    /// Esc closes Mission Control. Marked so the event tap lets it through.
    private static func postEscape() {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: isDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: replayedEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

/// One label as drawn.
struct HintChip: Equatable {
    let label: String
    let typed: String
    /// Still matches what has been typed; the others fade.
    let isMatch: Bool
    let isSelected: Bool
    /// The target, in AppKit screen coordinates.
    let frame: CGRect
}

/// Labels on one screen, a ring around the selection and, on the pointer's screen, the legend.
struct KeyboardHintsView: View {
    let hints: [HintChip]
    let screen: CGRect
    let legend: [KeyboardHints.LegendItem]?
    let legendArea: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(hints, id: \.label) { hint in
                let rect = OverlayCanvas.local(hint.frame, in: screen)
                if hint.isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 4)
                        .shadow(color: .black.opacity(0.35), radius: 4)
                        .placed(in: rect.insetBy(dx: -3, dy: -3), alignment: .center)
                }
                HintLabelView(hint: hint)
                    .placed(in: rect, alignment: .center)
            }
            if let legend {
                HintLegendView(items: legend)
                    .placed(in: legendArea, alignment: .bottom)
            }
        }
    }
}

/// A label in black on yellow, like Vimium's, with the typed letters dimmed.
struct HintLabelView: View {
    let hint: HintChip

    var body: some View {
        HStack(spacing: 0) {
            Text(hint.label.prefix(hint.typed.count).uppercased())
                .foregroundStyle(.black.opacity(0.35))
            Text(hint.label.dropFirst(hint.typed.count).uppercased())
                .foregroundStyle(hint.isSelected ? .white : .black)
        }
        .font(.system(size: 16, weight: .bold, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hint.isSelected ? Color.accentColor : Color(red: 1, green: 0.84, blue: 0.04))
        )
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        .opacity(hint.isMatch || hint.isSelected ? 1 : 0.3)
    }
}

/// "W Close · M Minimize · …" along the bottom of the screen.
struct HintLegendView: View {
    let items: [KeyboardHints.LegendItem]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.text) { item in
                HStack(spacing: 5) {
                    if let key = item.key {
                        Text(key)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(item.text)
                        .font(.system(size: 13, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }
}
