import SwiftUI

/// Settings for what MissionStrike draws over Mission Control to explain itself.
struct OverlaySettingsSection: View {
    @AppStorage(SettingKey.showWindowCounts.rawValue)
    private var showWindowCounts = SettingKey.showWindowCounts.defaultBool
    @AppStorage(SettingKey.enableKeyboardHints.rawValue)
    private var enableKeyboardHints = SettingKey.enableKeyboardHints.defaultBool

    var body: some View {
        Section("Overlays") {
            Toggle(isOn: $showWindowCounts) {
                Text("Window Counts")
                Text("While the modifier is held, show each window's app and how many windows it has here.")
            }

            Toggle(isOn: $enableKeyboardHints) {
                Text("Keyboard Hints")
                Text("Press F to label every window. Type a label, then W, M, H, Q or A to act, or Return to open it.")
            }
        }
    }
}
