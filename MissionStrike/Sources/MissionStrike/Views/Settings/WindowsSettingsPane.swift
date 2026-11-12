import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Snapping the window in front with shortcuts.
struct WindowsSettingsPane: View {
    @AppStorage(SettingKey.enableWindowSnapping.rawValue)
    private var enableWindowSnapping = SettingKey.enableWindowSnapping.defaultBool
    @AppStorage(SettingKey.enableSnapAssist.rawValue)
    private var enableSnapAssist = SettingKey.enableSnapAssist.defaultBool
    @AppStorage(SettingKey.showSnapPreviews.rawValue)
    private var showSnapPreviews = SettingKey.showSnapPreviews.defaultBool
    @State private var canCapture = SnapPreviews.isAllowed

    private static let screenRecordingSettings = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )! // swiftlint:disable:this force_unwrapping

    /// Back from System Settings: Screen Recording may have been turned on.
    private let appBecameActive = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enableWindowSnapping) {
                    Text("Snap with Shortcuts")
                    Text("Move the window in front to a side of the screen, or let it fill the screen.")
                }
                Toggle(isOn: $enableSnapAssist) {
                    Text("Choose a Window for the Rest")
                    Text("After a snap to a side, pick another window for the free part with its number or a click.")
                }
                .disabled(!enableWindowSnapping)
                Toggle(isOn: $showSnapPreviews) {
                    Text("Show Window Previews")
                    Text("Show a picture of each window instead of its app's icon. Needs Screen Recording access.")
                }
                .disabled(!enableWindowSnapping || !enableSnapAssist)
                if showSnapPreviews, !canCapture {
                    LabeledContent {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(Self.screenRecordingSettings)
                        }
                    } label: {
                        Label(
                            "Screen Recording is off for MissionStrike, so windows show their app's icon.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .symbolRenderingMode(.multicolor)
                    }
                }
            } footer: {
                Text("Press a side's shortcut again for a third, then two-thirds of the screen.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Shortcuts") {
                ForEach(SnapAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(key: SettingKey.snapShortcut(for: action))
                    }
                }
                Button("Restore Default Shortcuts") {
                    for action in SnapAction.allCases {
                        let key = SettingKey.snapShortcut(for: action)
                        UserDefaults.standard.set(key.defaultString, forKey: key.rawValue)
                    }
                }
            }
            .disabled(!enableWindowSnapping)
        }
        .formStyle(.grouped)
        .onChange(of: showSnapPreviews) {
            // Asks once; after that macOS only changes it in System Settings.
            if showSnapPreviews, !SnapPreviews.isAllowed {
                CGRequestScreenCaptureAccess()
            }
            canCapture = SnapPreviews.isAllowed
        }
        .onReceive(appBecameActive) { _ in
            canCapture = SnapPreviews.isAllowed
        }
    }
}

/// A field that records the next shortcut typed while it's active. Esc cancels; Delete clears.
/// A shortcut another snap action had moves here.
struct ShortcutRecorder: View {
    /// Read by the event tap, which lets every key through to the recorder meanwhile.
    @MainActor static var isRecording = false

    let key: SettingKey
    @AppStorage private var storage: String
    @State private var monitor: Any?

    init(key: SettingKey) {
        self.key = key
        _storage = AppStorage(wrappedValue: key.defaultString, key.rawValue)
    }

    private var isRecordingHere: Bool { monitor != nil }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecordingHere ? stop() : start()
            } label: {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .foregroundStyle(isRecordingHere ? Color.accentColor : .primary)

            if !storage.isEmpty, !isRecordingHere {
                Button {
                    storage = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove Shortcut")
            }
        }
        .onDisappear(perform: stop)
        // Closing Settings doesn't make the view disappear, and leaving for another app should
        // give the shortcuts back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stop() }
    }

    private var label: String {
        if isRecordingHere { return "Type Shortcut…" }
        return KeyShortcut(storage: storage)?.displayString ?? "Record Shortcut"
    }

    private func start() {
        guard !Self.isRecording else { return }
        Self.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        Self.isRecording = false
    }

    private func record(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        let shortcut = KeyShortcut(keyCode: Int64(event.keyCode), flags: flags)
        if shortcut.modifiers == 0 {
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
                return
            case kVK_Delete, kVK_ForwardDelete:
                storage = ""
                stop()
                return
            default:
                break
            }
        }
        guard shortcut.isAllowed else {
            NSSound.beep()
            return
        }
        for other in SnapAction.allCases.map(SettingKey.snapShortcut(for:)) where other != key {
            if UserDefaults.standard.string(other) == shortcut.storage {
                UserDefaults.standard.set("", forKey: other.rawValue)
            }
        }
        storage = shortcut.storage
        stop()
    }
}
