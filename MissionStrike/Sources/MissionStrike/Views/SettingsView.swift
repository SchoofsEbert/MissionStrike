import SwiftUI
import ServiceManagement
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "io.github.schoofsebert.missionstrike", category: "Settings")

struct SettingsView: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("enableSpaceClosing") private var enableSpaceClosing = true
    @AppStorage("enableMiddleClick") private var enableMiddleClick = true
    @AppStorage("enableContextMenu") private var enableContextMenu = true
    @AppStorage("enableKeyboardShortcuts") private var enableKeyboardShortcuts = true
    @AppStorage("showHoverBadge") private var showHoverBadge = true
    @AppStorage("poofOnClose") private var poofOnClose = false
    @AppStorage("enableDockMiddleClick") private var enableDockMiddleClick = false
    @AppStorage("leftClickModifier") private var leftClickModifier = "option"
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
            triggersSection
            actionsSection
            spacesSection
            dockSection
            generalSection
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
        .frame(width: 460, height: 700)
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
            LabeledContent("Accessibility") {
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
            }
        } header: {
            header
        }
    }

    // MARK: - Triggers

    private var triggersSection: some View {
        Section("Mission Control") {
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

            Toggle(isOn: $showHoverBadge) {
                Text("Hover Badge")
                Text("While the modifier is held, mark the window a click will act on.")
            }

            Toggle(isOn: $enableContextMenu) {
                Text("Right-Click Menu")
                Text("Close, minimize, hide or quit from a menu.")
            }

            Toggle(isOn: $enableKeyboardShortcuts) {
                Text("Keyboard Shortcuts")
                Text("⌘W, ⌘M, ⌘H and ⌘Q act on the window under the pointer.")
            }

            Toggle(isOn: $poofOnClose) {
                Text("Poof When Closing")
                Text("Show the classic puff of smoke where a window or Space was closed.")
            }
        }
    }

    // MARK: - Actions Reference

    private var actionsSection: some View {
        Section {
            LabeledContent("Close window", value: "Click")
            LabeledContent("Minimize to Dock", value: "⇧ Click")
            LabeledContent("Close all app windows", value: "⌘ Click")
        } header: {
            Text("Click Actions")
        } footer: {
            Text("Click means a middle-click or a modifier-click.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    // MARK: - Spaces

    private var spacesSection: some View {
        Section("Spaces") {
            Toggle(isOn: $enableSpaceClosing) {
                Text("Close Spaces with One Click")
                Text("Click a Space in the bar at the top to remove it, without waiting for its close button.")
            }
        }
    }

    // MARK: - Dock

    private var dockSection: some View {
        Section("Dock") {
            Toggle(isOn: $enableDockMiddleClick) {
                Text("Middle-Click to Quit")
                Text("Middle-click a running app in the Dock to quit it. Hold ⌥ to close its windows instead.")
            }
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
        } header: {
            Text("General")
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
