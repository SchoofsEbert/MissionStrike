import AppKit

/// How an action tells the user it went through or didn't, besides the window itself changing.
@MainActor
enum ActionFeedback {
    /// Reduce Motion is on: shakes, pulses and the poof's drift give way to plain fades.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// One trackpad tap for a close, minimize or Space removal that went through.
    static func succeeded() {
        guard SettingsStore.shared.current.hapticFeedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// Shakes a grey × badge at each anchor (AppKit screen coordinates), or the hover badge
    /// while it shows; beeps when there's nowhere to put one.
    static func failed(at anchors: [CGRect]) {
        if !HoverBadgeController.shared.showFailure(at: anchors) {
            NSSound.beep()
        }
    }
}
