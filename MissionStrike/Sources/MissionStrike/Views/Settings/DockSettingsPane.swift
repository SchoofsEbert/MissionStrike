import SwiftUI

/// Clicks on app icons in the Dock, outside Mission Control.
struct DockSettingsPane: View {
    @AppStorage(SettingKey.enableDockMiddleClick.rawValue)
    private var enableDockMiddleClick = SettingKey.enableDockMiddleClick.defaultBool

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enableDockMiddleClick) {
                    Text("Middle-Click to Quit")
                    Text("Middle-click a running app in the Dock to quit it. Hold ⌥ to close its windows instead.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
