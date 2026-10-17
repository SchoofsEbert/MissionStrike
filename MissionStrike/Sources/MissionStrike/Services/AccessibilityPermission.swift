import AppKit
import ApplicationServices

/// Asks for Accessibility access. macOS shows its own prompt only once, so after that
/// a request opens the Accessibility list in System Settings instead.
@MainActor
enum AccessibilityPermission {
    /// Set once the system prompt has run and MissionStrike is in the Accessibility list.
    private static let promptShownKey = "accessibilityPromptShown"

    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// Shows the system prompt the first time, and opens System Settings after that.
    static func request() {
        if UserDefaults.standard.bool(forKey: promptShownKey) {
            openSettings()
        } else {
            showSystemPrompt()
        }
    }

    /// Shows the system prompt, which also adds MissionStrike to the Accessibility list.
    static func showSystemPrompt() {
        markPromptShown()
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Records that MissionStrike is already in the Accessibility list, e.g. because it is trusted.
    static func markPromptShown() {
        UserDefaults.standard.set(true, forKey: promptShownKey)
    }
}
