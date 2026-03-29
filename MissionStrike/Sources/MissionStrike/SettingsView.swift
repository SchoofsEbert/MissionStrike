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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 15) {
                if let nsImage = NSApplication.shared.applicationIconImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }

                Text("MissionStrike Settings")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: isAccessibilityEnabled
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(isAccessibilityEnabled ? .green : .orange)
                    Text("Accessibility Permissions")
                }

                if !isAccessibilityEnabled {
                    Button("Open System Settings") {
                        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                    .font(.caption)
                }
            }

            // --- Trigger Bindings ---
            VStack(alignment: .leading, spacing: 8) {
                Text("Trigger Bindings")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Toggle("Middle Mouse Click", isOn: $enableMiddleClick)

                HStack {
                    Text("Left Click Modifier:")
                    Picker("", selection: $leftClickModifier) {
                        ForEach(TriggerModifier.allCases, id: \.rawValue) { modifier in
                            Text(modifier.displayName).tag(modifier.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            // --- General ---
            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)

            Toggle("Enable Closing Spaces", isOn: $enableSpaceClosing)

            Toggle("Start at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    toggleLaunchAtLogin()
                }

            Text("Actions in Mission Control:\n"
                 + "• Click → Close window\n"
                 + "• ⇧ Shift + Click → Minimize window\n"
                 + "• ⌘ Cmd + Click → Close all app windows")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(accessibilityChanged) { _ in
            refreshAccessibilityStatus()
        }
        .padding()
        .frame(width: 340, height: 420)
    }

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
