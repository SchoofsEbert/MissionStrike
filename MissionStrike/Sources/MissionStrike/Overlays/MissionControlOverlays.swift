import AppKit
import CoreGraphics

extension Notification.Name {
    /// Posted on the main thread by `MissionControlManager` after it closed, minimized, hid or
    /// quit something, or removed a Space.
    static let missionStrikeActionSucceeded = Notification.Name("io.github.schoofsebert.missionstrike.actionSucceeded")
}

/// Ties the overlays drawn over Mission Control to the event tap and to Mission Control opening
/// and closing. The tap calls in from its callback, so what runs from there only touches stored
/// state and panels, never Accessibility.
@MainActor
enum MissionControlOverlays {
    private static var observers: [NSObjectProtocol] = []

    /// After Mission Control's key or a swipe, when to look whether it opened.
    private static let openingChecks: [Duration] = [.milliseconds(350), .milliseconds(900)]
    private static var lastOpeningSignal: ContinuousClock.Instant?
    private static var isCheckingForOpening = false

    static func startObserving() {
        guard observers.isEmpty else { return }
        observers = [
            observe(.missionControlDidOpen) {
                FirstRunHint.shared.missionControlDidOpen()
            },
            observe(.missionControlDidClose) {
                WindowCountChips.shared.hide()
                KeyboardHints.shared.cancel()
                CheatSheet.shared.dismiss()
                FirstRunHint.shared.missionControlDidClose()
                MissionControlThumbnails.shared.forget()
            },
            observe(.missionStrikeActionSucceeded) {
                FirstRunHint.shared.actionSucceeded()
                MissionControlThumbnails.shared.forget()
                WindowCountChips.shared.layoutMayHaveChanged()
            }
        ]
    }

    /// These notifications are posted on the main thread, sometimes from inside the tap callback.
    private static func observe(_ name: Notification.Name, _ body: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { body() }
        }
    }

    // MARK: - From the event tap

    static func modifiersChanged(_ flags: CGEventFlags) {
        WindowCountChips.shared.modifiersChanged(flags)
        CheatSheet.shared.modifiersChanged(flags)
    }

    /// A mouse or key press, before its decision is carried out. A click ends keyboard hints
    /// and closes the cheat sheet; so does a key press neither of them takes.
    static func pressed(_ type: CGEventType, decision: TapDecision) {
        guard type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown else { return }
        switch decision {
        case .keyboardHint, .toggleCheatSheet, .closeCheatSheet:
            break
        case .startKeyboardHints:
            CheatSheet.shared.dismiss()
        default:
            KeyboardHints.shared.cancel()
            CheatSheet.shared.dismiss()
        }
    }

    /// Mission Control's key or a trackpad swipe may be opening Mission Control. Nothing else
    /// would notice until the next click or key, so look shortly after, while the first-run tip
    /// is still to be shown. Cheap: only notes the time, the checks run in a task.
    static func missionControlMayOpen() {
        guard FirstRunHint.shared.isPending else { return }
        lastOpeningSignal = .now
        guard !isCheckingForOpening else { return }
        isCheckingForOpening = true
        Task { @MainActor in
            defer { isCheckingForOpening = false }
            for delay in openingChecks {
                // Swipes send a stream of events: count from the last one.
                while let last = lastOpeningSignal, ContinuousClock.now < last + delay {
                    try? await Task.sleep(until: last + delay, clock: .continuous)
                }
                if MissionControlSession.isActive(maxAge: .zero) { return }
            }
        }
    }
}

extension TriggerModifier {
    /// The key's symbol, as in "⌥-click"; nil when disabled.
    var symbol: String? {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        case .disabled: nil
        }
    }
}

extension Settings {
    /// The clicks that close a window, as the overlays name them: "middle-click", "⌥-click".
    var closeClickNames: [String] {
        var names: [String] = []
        if enableMiddleClick { names.append("middle-click") }
        if let symbol = leftClickModifier?.symbol { names.append("\(symbol)-click") }
        return names
    }
}
