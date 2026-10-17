import SwiftUI

/// Settings for what MissionStrike draws over Mission Control to explain itself.
struct OverlaySettingsSection: View {
    @AppStorage(SettingKey.showWindowCounts.rawValue)
    private var showWindowCounts = SettingKey.showWindowCounts.defaultBool
    @AppStorage(SettingKey.enableKeyboardHints.rawValue)
    private var enableKeyboardHints = SettingKey.enableKeyboardHints.defaultBool
    @AppStorage(SettingKey.showCheatSheet.rawValue)
    private var showCheatSheet = SettingKey.showCheatSheet.defaultBool
    @AppStorage(SettingKey.showFirstRunHint.rawValue)
    private var showFirstRunHint = SettingKey.showFirstRunHint.defaultBool

    var body: some View {
        Section("Overlays") {
            Toggle(isOn: $showWindowCounts) {
                Text("Window Counts")
                Text("While the modifier is held, label each window with its app and how many of that app's windows are showing.")
            }

            Toggle(isOn: $enableKeyboardHints) {
                Text("Keyboard Hints")
                Text("Press F to label every window. Type a label, then W, M, H, Q or A to act, or Return to open it.")
            }

            Toggle(isOn: $showCheatSheet) {
                Text("Cheat Sheet")
                Text("Hold the modifier for a second, or press ?, to see every gesture.")
            }

            Toggle(isOn: $showFirstRunHint) {
                Text("Getting Started Tip")
                Text("The first few times Mission Control opens, show how to close a window.")
            }
        }
    }
}
