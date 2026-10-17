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

    static func startObserving() {
        guard observers.isEmpty else { return }
        observers = [
            observe(.missionControlDidClose) {
                WindowCountChips.shared.hide()
                KeyboardHints.shared.cancel()
                MissionControlThumbnails.shared.forget()
            },
            observe(.missionStrikeActionSucceeded) {
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
    }

    /// A mouse or key press, before its decision is carried out. A click ends keyboard hints;
    /// so does a key press they don't take.
    static func pressed(_ type: CGEventType, decision: TapDecision) {
        guard type == .keyDown || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown else { return }
        switch decision {
        case .keyboardHint, .startKeyboardHints:
            break
        default:
            KeyboardHints.shared.cancel()
        }
    }
}
