import SwiftUI

/// Settings for what MissionStrike draws over Mission Control to explain itself.
struct OverlaySettingsSection: View {
    @AppStorage(SettingKey.showWindowCounts.rawValue)
    private var showWindowCounts = SettingKey.showWindowCounts.defaultBool

    var body: some View {
        Section("Overlays") {
            Toggle(isOn: $showWindowCounts) {
                Text("Window Counts")
                Text("While the modifier is held, show each window's app and how many windows it has here.")
            }
        }
    }
}
