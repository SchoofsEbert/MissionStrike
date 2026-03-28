import SwiftUI
import ServiceManagement
import ApplicationServices

struct SettingsView: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isAccessibilityEnabled = AXIsProcessTrusted()

    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                    Image(systemName: isAccessibilityEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(isAccessibilityEnabled ? .green : .orange)
                    Text("Accessibility Permissions")
                }

                if !isAccessibilityEnabled {
                    Button("Open System Settings") {
                        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                        AXIsProcessTrustedWithOptions(options)
                    }
                    .font(.caption)
                }
            }

            Toggle("Show Menu Bar Icon", isOn: $showMenuBarIcon)

            Toggle("Start at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue {
                            if SMAppService.mainApp.status != .enabled {
                                try SMAppService.mainApp.register()
                            }
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("Failed to toggle launch at login: \(error)")
                        // Revert the toggle if it fails
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Text("MissionStrike allows you to close windows in Mission Control using:\n• Middle Mouse Click\n• Option + Left Click")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .onReceive(timer) { _ in
            isAccessibilityEnabled = AXIsProcessTrusted()
        }
        .padding()
        .frame(width: 320, height: 300)
    }
}
