import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("MissionStrike Settings")
                .font(.headline)

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
        .padding()
        .frame(width: 300, height: 250)
    }
}
