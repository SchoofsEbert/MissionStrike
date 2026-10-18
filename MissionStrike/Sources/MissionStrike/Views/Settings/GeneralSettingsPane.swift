import SwiftUI
import ServiceManagement
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "Settings")

/// Permission, menu bar and login settings, plus links to the other windows.
struct GeneralSettingsPane: View {
    @AppStorage(SettingKey.showMenuBarIcon.rawValue)
    private var showMenuBarIcon = SettingKey.showMenuBarIcon.defaultBool
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()
    @State private var accessibilityRetryTask: Task<Void, Never>?

    /// Fires when any app's accessibility trust status changes in System Settings.
    private let accessibilityChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if isAccessibilityEnabled {
                        Label {
                            Text("Allowed")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Button("Grant Access…") {
                            AccessibilityPermission.request()
                        }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Needed to see and act on windows in Mission Control.")
                }
            }

            Section {
                Toggle("Show in Menu Bar", isOn: $showMenuBarIcon)

                Toggle("Start at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        toggleLaunchAtLogin()
                    }
            }

            Section {
                LabeledContent("Software Update") {
                    Button("Check for Updates…") {
                        UpdateChecker.shared.checkNow()
                    }
                }

                LabeledContent("Setup Guide") {
                    Button("Open…") {
                        (NSApp.delegate as? AppDelegate)?.openOnboardingWindow()
                    }
                }

                LabeledContent("About MissionStrike") {
                    Button("Show…") {
                        (NSApp.delegate as? AppDelegate)?.openAboutWindow()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onDisappear {
            accessibilityRetryTask?.cancel()
            accessibilityRetryTask = nil
        }
        .onReceive(accessibilityChanged) { _ in
            accessibilityRetryTask?.cancel()
            accessibilityRetryTask = AccessibilityTrustRetry.schedule {
                refreshAccessibilityStatus()
            }
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
