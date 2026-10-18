import SwiftUI

/// How windows and Spaces are acted on inside Mission Control: by mouse and by keyboard.
struct MissionControlSettingsPane: View {
    @AppStorage(SettingKey.enableMiddleClick.rawValue)
    private var enableMiddleClick = SettingKey.enableMiddleClick.defaultBool
    @AppStorage(SettingKey.leftClickModifier.rawValue)
    private var leftClickModifier = SettingKey.leftClickModifier.defaultString
    @AppStorage(SettingKey.enableContextMenu.rawValue)
    private var enableContextMenu = SettingKey.enableContextMenu.defaultBool
    @AppStorage(SettingKey.enableKeyboardShortcuts.rawValue)
    private var enableKeyboardShortcuts = SettingKey.enableKeyboardShortcuts.defaultBool
    @AppStorage(SettingKey.enableKeyboardHints.rawValue)
    private var enableKeyboardHints = SettingKey.enableKeyboardHints.defaultBool
    @AppStorage(SettingKey.enableSpaceClosing.rawValue)
    private var enableSpaceClosing = SettingKey.enableSpaceClosing.defaultBool

    var body: some View {
        Form {
            mouseSection
            keyboardSection
            spacesSection
        }
        .formStyle(.grouped)
    }

    private var mouseSection: some View {
        Section {
            Toggle(isOn: $enableMiddleClick) {
                Text("Middle-Click")
                Text("Middle-click a window to close it.")
            }

            Picker(selection: $leftClickModifier) {
                ForEach(TriggerModifier.allCases, id: \.rawValue) { modifier in
                    Text(modifier.displayName).tag(modifier.rawValue)
                }
            } label: {
                Text("Left-Click Modifier")
                Text("Hold this key and click instead of middle-clicking.")
            }

            Toggle(isOn: $enableContextMenu) {
                Text("Right-Click Menu")
                Text("Close, minimize, hide or quit from a menu.")
            }
        } header: {
            Text("Mouse")
        } footer: {
            Text("A click closes the window under the pointer. Add ⇧ to minimize it to the Dock, "
                + "or ⌘ to close all of that app's windows.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var keyboardSection: some View {
        Section("Keyboard") {
            Toggle(isOn: $enableKeyboardShortcuts) {
                Text("Keyboard Shortcuts")
                Text("⌘W, ⌘M, ⌘H and ⌘Q act on the window under the pointer.")
            }

            Toggle(isOn: $enableKeyboardHints) {
                Text("Keyboard Hints")
                Text("Press F to label every window. Type a label, then W, M, H, Q or A to act, or Return to open it.")
            }
        }
    }

    private var spacesSection: some View {
        Section("Spaces") {
            Toggle(isOn: $enableSpaceClosing) {
                Text("Close Spaces with One Click")
                Text("Click a Space in the bar at the top to remove it, without waiting for its close button.")
            }
        }
    }
}
