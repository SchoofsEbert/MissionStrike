import SwiftUI
import ServiceManagement
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.vibecoded.missionstrike", category: "Settings")

struct SettingsView: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("enableSpaceClosing") private var enableSpaceClosing = true
    @AppStorage("enableMiddleClick") private var enableMiddleClick = true
    @AppStorage("leftClickModifier") private var leftClickModifier = "option"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()

    /// Fires when any app's accessibility trust status changes in System Settings.
    private let accessibilityChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    var body: some View {
        Form {
            // MARK: - Status
            Section {
                HStack(spacing: 10) {
                    Image(systemName: isAccessibilityEnabled
                          ? "checkmark.shield.fill"
                          : "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(isAccessibilityEnabled ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .fontWeight(.medium)
                        Text(isAccessibilityEnabled
                             ? "Permissions granted — MissionStrike is active."
                             : "Permissions required for MissionStrike to work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !isAccessibilityEnabled {
                        Button("Grant Access") {
                            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                            _ = AXIsProcessTrustedWithOptions(options)
                        }
                        .controlSize(.small)
                    }
                }
            }

            // MARK: - Triggers
            Section {
                Toggle("Middle Mouse Button", isOn: $enableMiddleClick)

                Picker("Left Click Modifier", selection: $leftClickModifier) {
                    ForEach(TriggerModifier.allCases, id: \.rawValue) { modifier in
                        Text(modifier.displayName).tag(modifier.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Trigger Bindings")
            } footer: {
                Text("Choose how to trigger actions in Mission Control.\nCommand and Shift are reserved as action modifiers.")
            }

            // MARK: - Actions Reference
            Section {
                VStack(spacing: 0) {
                    actionRow(
                        keys: "Click",
                        description: "Close window",
                        icon: "xmark.circle"
                    )
                    Divider().padding(.vertical, 6)
                    actionRow(
                        keys: "⇧ Shift + Click",
                        description: "Minimize to Dock",
                        icon: "minus.circle"
                    )
                    Divider().padding(.vertical, 6)
                    actionRow(
                        keys: "⌘ Cmd + Click",
                        description: "Close all app windows",
                        icon: "xmark.circle.fill"
                    )
                }
                .padding(.vertical, 2)
            } header: {
                Text("Actions in Mission Control")
            }

            // MARK: - Spaces
            Section {
                Toggle("Enable Closing Spaces", isOn: $enableSpaceClosing)
            } header: {
                Text("Spaces")
            } footer: {
                Text("When enabled, clicking a Space in the top bar\nremoves it instantly — no hover delay.")
            }

            // MARK: - General
            Section("General") {
                Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)

                Toggle("Start at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        toggleLaunchAtLogin()
                    }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(accessibilityChanged) { _ in
            refreshAccessibilityStatus()
        }
        .frame(width: 420, height: 560)
    }

    // MARK: - Action Row

    private func actionRow(keys: String, description: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(description)
                .font(.callout)

            Spacer()

            Text(keys)
                .font(.caption)
                .fontDesign(.rounded)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    // MARK: - Logic

    private func refreshAccessibilityStatus() {
        let wasEnabled = isAccessibilityEnabled
        isAccessibilityEnabled = AXIsProcessTrusted()

        // When permissions are freshly granted, start the event tap immediately
        if !wasEnabled && isAccessibilityEnabled {
            EventTapManager.shared.start()
        }
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to toggle launch at login: \(error.localizedDescription)")
            // Revert the toggle if it fails
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
