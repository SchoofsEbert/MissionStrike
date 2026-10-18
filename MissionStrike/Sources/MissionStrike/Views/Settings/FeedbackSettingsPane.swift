import SwiftUI

/// What MissionStrike draws over Mission Control to explain itself, and how it confirms an action.
struct FeedbackSettingsPane: View {
    @AppStorage(SettingKey.leftClickModifier.rawValue)
    private var leftClickModifier = SettingKey.leftClickModifier.defaultString
    @AppStorage(SettingKey.showHoverBadge.rawValue)
    private var showHoverBadge = SettingKey.showHoverBadge.defaultBool
    @AppStorage(SettingKey.showWindowCounts.rawValue)
    private var showWindowCounts = SettingKey.showWindowCounts.defaultBool
    @AppStorage(SettingKey.showCheatSheet.rawValue)
    private var showCheatSheet = SettingKey.showCheatSheet.defaultBool
    @AppStorage(SettingKey.showFirstRunHint.rawValue)
    private var showFirstRunHint = SettingKey.showFirstRunHint.defaultBool
    @AppStorage(SettingKey.poofOnClose.rawValue)
    private var poofOnClose = SettingKey.poofOnClose.defaultBool
    @AppStorage(SettingKey.hapticFeedback.rawValue)
    private var hapticFeedback = SettingKey.hapticFeedback.defaultBool

    /// The symbol of the held key the hover badge and window counts appear for; nil when the
    /// left-click trigger is off.
    private var modifier: String? {
        TriggerModifier(rawValue: leftClickModifier)?.symbol
    }

    var body: some View {
        Form {
            whileHoldingSection
            guidanceSection
            effectsSection
        }
        .formStyle(.grouped)
    }

    private var whileHoldingSection: some View {
        Section {
            Toggle(isOn: $showHoverBadge) {
                Text("Hover Badge")
                Text("Mark the window a click will act on.")
            }

            Toggle(isOn: $showWindowCounts) {
                Text("Window Counts")
                Text("Label each window with its app and how many of that app's windows are showing.")
            }
        } header: {
            if let modifier {
                Text("While \(modifier) Is Held")
            } else {
                Text("While the Modifier Is Held")
            }
        } footer: {
            if modifier == nil {
                Text("Choose a left-click modifier in Mission Control settings to use these.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .disabled(modifier == nil)
    }

    private var guidanceSection: some View {
        Section("Guidance") {
            Toggle(isOn: $showCheatSheet) {
                Text("Cheat Sheet")
                Text(modifier == nil
                    ? "Press ? in Mission Control to see every gesture."
                    : "Hold the modifier for a second, or press ?, to see every gesture.")
            }

            Toggle(isOn: $showFirstRunHint) {
                Text("Getting Started Tip")
                Text("The first few times Mission Control opens, show how to close a window.")
            }
        }
    }

    private var effectsSection: some View {
        Section("Effects") {
            Toggle(isOn: $poofOnClose) {
                Text("Poof When Closing")
                Text("Show the classic puff of smoke where a window or Space was closed.")
            }

            Toggle(isOn: $hapticFeedback) {
                Text("Haptic Feedback")
                Text("Tap the trackpad when a window closes or minimizes.")
            }
        }
    }
}
