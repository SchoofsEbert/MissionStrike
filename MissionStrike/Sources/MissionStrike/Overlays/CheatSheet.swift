import AppKit
import SwiftUI

/// A card in the middle of the screen listing every gesture and shortcut as the settings have
/// them. Shows once the trigger modifier has been held for a second with the pointer at rest,
/// and goes when it's released; or press `?`, and it stays until Esc, another key or a click.
@MainActor
final class CheatSheet {
    static let shared = CheatSheet()
    private init() {}

    struct Row: Equatable {
        let keys: String
        let action: String
    }

    private static let holdDelay: Duration = .seconds(1)
    /// Moving the pointer further than this while the modifier is held is aiming, not waiting
    /// for help: the second starts over.
    private static let restDistance: CGFloat = 24

    private let canvas = OverlayCanvas()
    /// Opened with `?`. Read by the event tap, so Esc can close it and leave Mission Control open.
    private(set) var isPinned = false
    private var isShownForHold = false
    /// Whether the modifier is down; a click while it's down cancels the card until it's pressed again.
    private var isHolding = false
    private var generation = 0

    /// Called from the event tap on every modifier change. Cheap: the wait runs in a task.
    func modifiersChanged(_ flags: CGEventFlags) {
        let settings = SettingsStore.shared.current
        guard settings.showCheatSheet, let mask = settings.leftClickModifier?.eventFlagMask, flags.contains(mask) else {
            isHolding = false
            if !isPinned {
                dismiss()
            }
            return
        }
        guard !isHolding, !isPinned else { return }
        isHolding = true
        guard MissionControlSession.isActive() else { return }
        generation += 1
        let generation = generation
        Task { @MainActor in
            var anchor = NSEvent.mouseLocation
            while true {
                try? await Task.sleep(for: Self.holdDelay)
                guard generation == self.generation else { return }
                let pointer = NSEvent.mouseLocation
                if hypot(pointer.x - anchor.x, pointer.y - anchor.y) <= Self.restDistance { break }
                anchor = pointer
            }
            guard MissionControlSession.isActive(), !MissionControlContextMenu.isOpen, !KeyboardHints.shared.isActive else {
                return
            }
            isShownForHold = true
            show()
        }
    }

    /// `?`: shows the card until it's dismissed, or hides it.
    func toggle() {
        if isPinned || isShownForHold {
            dismiss()
            return
        }
        generation += 1
        isPinned = true
        // Not from inside the tap callback, which pressing `?` runs in.
        Task { @MainActor in
            guard isPinned else { return }
            show()
        }
    }

    /// Hides the card and cancels a pending one. Cheap enough for the tap callback.
    func dismiss() {
        generation += 1
        isPinned = false
        isShownForHold = false
        canvas.hide()
    }

    private func show() {
        let settings = SettingsStore.shared.current
        let rows = Self.rows(for: settings, keyboardHintsAvailable: MissionControlHitTester.shouldYFlipForMissionControl())
        let notes = Self.notes(for: settings)
        canvas.show(on: OverlayCanvas.pointerScreen.map { [$0] } ?? []) { _ in
            CheatSheetCard(rows: rows, notes: notes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Every gesture and shortcut that's switched on. Keyboard hints need the `wid` thumbnails
    /// of macOS 27's Mission Control.
    static func rows(for settings: Settings, keyboardHintsAvailable: Bool) -> [Row] {
        var rows: [Row] = []
        if !settings.closeClickNames.isEmpty {
            rows.append(Row(keys: "Click", action: settings.enableSpaceClosing ? "Close a window or Space" : "Close a window"))
            rows.append(Row(keys: "⇧ Click", action: "Minimize the window"))
            rows.append(Row(keys: "⌘ Click", action: "Close all of the app's windows"))
        }
        if settings.enableContextMenu {
            rows.append(Row(keys: "Right-click", action: "More, like Hide and Quit"))
        }
        if settings.enableKeyboardShortcuts {
            rows.append(Row(keys: "⌘W ⌘M ⌘H ⌘Q", action: "Close, minimize, hide or quit what's under the pointer"))
        }
        if settings.enableKeyboardHints, keyboardHintsAvailable {
            rows.append(Row(keys: "F", action: "Pick a window with the keyboard"))
        }
        if settings.enableDockMiddleClick {
            rows.append(Row(keys: "Middle-click in Dock", action: "Quit the app, or with ⌥ close its windows"))
        }
        return rows
    }

    /// What "Click" means, and how to bring the card back.
    static func notes(for settings: Settings) -> [String] {
        var notes: [String] = []
        let clicks = settings.closeClickNames
        if !clicks.isEmpty {
            notes.append("Click means a \(clicks.joined(separator: " or ")).")
        }
        if let symbol = settings.leftClickModifier?.symbol {
            notes.append("Hold \(symbol) for a second or press ? to see this again.")
        } else {
            notes.append("Press ? to see this again.")
        }
        return notes
    }
}

/// The cheat sheet: keys on the left, what they do on the right.
struct CheatSheetCard: View {
    let rows: [CheatSheet.Row]
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MissionStrike")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                ForEach(rows, id: \.keys) { row in
                    GridRow {
                        Text(row.keys)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .gridColumnAlignment(.trailing)
                        Text(row.action)
                            .font(.system(size: 13))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
    }
}
