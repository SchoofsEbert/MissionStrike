import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Trackpad gestures that work everywhere, outside Mission Control.
struct TrackpadSettingsPane: View {
    @AppStorage(SettingKey.enableTabSwipe.rawValue)
    private var enableTabSwipe = SettingKey.enableTabSwipe.defaultBool
    @AppStorage(SettingKey.tabSwipeHaptics.rawValue)
    private var tabSwipeHaptics = SettingKey.tabSwipeHaptics.defaultBool
    @AppStorage(SettingKey.tabSwipeAppScope.rawValue)
    private var scope = TabSwipeAppScope.allApps
    /// `@AppStorage` doesn't hold arrays: written back to the defaults on every change.
    @State private var bundleIDs = UserDefaults.standard.strings(.tabSwipeApps)
    @State private var conflicts = TabSwipeConflict.current()

    /// Back from System Settings: the trackpad gestures may have changed.
    private let appBecameActive = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enableTabSwipe) {
                    Text("Swipe Between Tabs")
                    Text("Swipe left or right with three fingers for the previous or next tab, in any app that switches tabs with ⌃⇥. Swipe further to skip more tabs.")
                }
                Toggle(isOn: $tabSwipeHaptics) {
                    Text("Tick for Each Tab")
                    Text("Tap the trackpad lightly each time the tab changes.")
                }
                .disabled(!enableTabSwipe)
            }

            if enableTabSwipe, !conflicts.isEmpty {
                conflictsSection
            }

            appsSection
                .disabled(!enableTabSwipe)
        }
        .formStyle(.grouped)
        .onReceive(appBecameActive) { _ in
            conflicts = TabSwipeConflict.current()
        }
        .onChange(of: bundleIDs) {
            UserDefaults.standard.set(bundleIDs, forKey: SettingKey.tabSwipeApps.rawValue)
        }
    }

    private var conflictsSection: some View {
        Section {
            ForEach(conflicts) { conflict in
                Label {
                    Text(conflict.message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            LabeledContent("Trackpad") {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var appsSection: some View {
        Section {
            Picker("Works In", selection: $scope) {
                ForEach(TabSwipeAppScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }

            if scope != .allApps {
                ForEach(listedApps) { app in
                    LabeledContent {
                        Button {
                            bundleIDs.removeAll { $0 == app.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.name)")
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                    }
                }

                LabeledContent {
                    addAppMenu
                } label: {
                    if bundleIDs.isEmpty {
                        Text(scope == .onlyListed ? "Add the apps to switch tabs in." : "Add the apps to leave alone.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Running apps first, since the app to add is usually open; any other app from a panel.
    private var addAppMenu: some View {
        Menu("Add App") {
            ForEach(runningApps) { app in
                Button {
                    add([app.id])
                } label: {
                    Label {
                        Text(app.name)
                    } icon: {
                        Image(nsImage: app.icon)
                    }
                }
            }
            if !runningApps.isEmpty {
                Divider()
            }
            Button("Choose…") {
                chooseApps()
            }
        }
        .fixedSize()
    }

    private var listedApps: [ListedApp] {
        bundleIDs.map(ListedApp.init(bundleID:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var runningApps: [ListedApp] {
        let listed = Set(bundleIDs)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !listed.contains($0) && $0 != Bundle.main.bundleIdentifier }
            .map(ListedApp.init(bundleID:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func add(_ ids: [String]) {
        bundleIDs.append(contentsOf: ids.filter { !bundleIDs.contains($0) })
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }
}

/// An app by bundle ID, with the name and icon of its installed copy.
private struct ListedApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    init(bundleID: String) {
        id = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            // Uninstalled since it was added.
            name = bundleID
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}
