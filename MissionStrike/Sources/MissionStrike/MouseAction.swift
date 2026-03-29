import CoreGraphics

/// The action to perform when a Mission Control click is detected.
enum MouseAction: Sendable {
    /// Close the single window under the cursor.
    case close
    /// Close all windows belonging to the same app.
    case closeAll
    /// Minimize the window under the cursor to the Dock.
    case minimize
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
