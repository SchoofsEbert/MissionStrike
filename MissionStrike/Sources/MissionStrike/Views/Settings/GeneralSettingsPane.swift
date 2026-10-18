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

    private let appVersion: String = {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "2.6.1"
    }()

    /// Fires when any app's accessibility trust status changes in System Settings.
    private let accessibilityChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    var body: some View {
        Form {
            statusSection
            generalSection
        }
        .settingsPane(height: 330)
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

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("MissionStrike")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text("Version \(appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .textCase(nil)
    }

    // MARK: - Status

    private var statusSection: some View {
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
        } header: {
            header
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)

            Toggle("Start at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    toggleLaunchAtLogin()
                }
        } footer: {
            footerLinks
        }
    }

    // MARK: - Footer Links

    private var footerLinks: some View {
        HStack(spacing: 16) {
            Button("Check for Updates…") {
                UpdateChecker.shared.checkNow()
            }
            Button("Setup Guide") {
                (NSApp.delegate as? AppDelegate)?.openOnboardingWindow()
            }
            Button("About MissionStrike") {
                (NSApp.delegate as? AppDelegate)?.openAboutWindow()
            }
        }
        .buttonStyle(.link)
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
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
