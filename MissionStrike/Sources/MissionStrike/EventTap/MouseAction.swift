import CoreGraphics

/// The action to perform when a Mission Control click is detected.
enum MouseAction: Sendable {
    /// Close the single window under the cursor.
    case close
    /// Close all windows belonging to the same app.
    case closeAll
    /// Minimize the window under the cursor to the Dock.
    case minimize

    /// ⌘ closes all of the app's windows, ⇧ minimizes, anything else closes the one window.
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

/// Available modifier keys for the left-click trigger.
/// Option and Control are offered; Command and Shift are reserved
/// for action modifiers (close-all and minimize respectively).
enum TriggerModifier: String, CaseIterable, Sendable {
    case option
    case control
    case disabled

    var displayName: String {
        switch self {
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .disabled: "Disabled"
        }
    }

    /// The corresponding `CGEventFlags` mask, if any.
    var eventFlagMask: CGEventFlags? {
        switch self {
        case .option: .maskAlternate
        case .control: .maskControl
        case .disabled: nil
        }
    }
}

/// Decides whether a mouse-down is one of MissionStrike's click triggers.
enum ClickTrigger {
    /// Middle-click when enabled, or a left-click with the configured modifier held.
    static func matches(
        type: CGEventType,
        buttonNumber: Int64,
        flags: CGEventFlags,
        middleClickEnabled: Bool,
        leftClickModifier: TriggerModifier?
    ) -> Bool {
        switch type {
        case .otherMouseDown:
            return buttonNumber == 2 && middleClickEnabled
        case .leftMouseDown:
            guard let mask = leftClickModifier?.eventFlagMask else { return false }
            return flags.contains(mask)
        default:
            return false
        }
    }
}

/// Mouse-ups whose mouse-down MissionStrike swallowed. The ups are swallowed too;
/// otherwise they reach Mission Control (or land on a freshly opened menu).
struct SwallowedMouseUps: Equatable {
    private var pending: Set<CGEventType> = []

    /// Swallow the release that belongs to this press.
    mutating func swallowRelease(of press: CGEventType) {
        if let up = Self.release(of: press) {
            pending.insert(up)
        }
    }

    /// True when this mouse-up belongs to a swallowed press; it is then forgotten.
    mutating func consume(_ up: CGEventType) -> Bool {
        pending.remove(up) != nil
    }

    /// A new press means any up still pending from an earlier swallowed press was lost
    /// (e.g. while the tap was disabled). Forget it so it can't eat this press's release.
    mutating func forgetLostRelease(beforePress press: CGEventType) {
        if let up = Self.release(of: press) {
            pending.remove(up)
        }
    }

    static func isMouseUp(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: true
        default: false
        }
    }

    private static func release(of press: CGEventType) -> CGEventType? {
        switch press {
        case .leftMouseDown: .leftMouseUp
        case .rightMouseDown: .rightMouseUp
        case .otherMouseDown: .otherMouseUp
        default: nil
        }
    }
}
