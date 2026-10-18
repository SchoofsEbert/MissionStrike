import AppKit
import SwiftUI

/// The panes of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case missionControl
    case feedback
    case dock

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .missionControl: "Mission Control"
        case .feedback: "Feedback"
        case .dock: "Dock"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .missionControl: "rectangle.3.group.fill"
        case .feedback: "sparkles"
        case .dock: "dock.rectangle"
        }
    }

    /// The fill behind the sidebar icon, as System Settings colours its panes.
    var tint: Color {
        switch self {
        case .general: .gray
        case .missionControl: .blue
        case .feedback: .pink
        case .dock: Color(white: 0.15)
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettingsPane()
        case .missionControl: MissionControlSettingsPane()
        case .feedback: FeedbackSettingsPane()
        case .dock: DockSettingsPane()
        }
    }
}

/// A sidebar of panes beside the selected pane's form, laid out like System Settings.
struct SettingsView: View {
    @State private var selection: SettingsPane? = .general
    /// Called with each pane shown, so the window can take its title.
    var onShow: (SettingsPane) -> Void = { _ in }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SettingsSidebarHeader()

                Section {
                    ForEach(SettingsPane.allCases) { pane in
                        NavigationLink(value: pane) {
                            Label {
                                Text(pane.title)
                            } icon: {
                                SettingsPaneIcon(pane: pane)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            (selection ?? .general).content
        }
        .frame(width: 715, height: 620)
        .onChange(of: selection, initial: true) {
            onShow(selection ?? .general)
        }
    }
}

/// The app's icon, name and version at the top of the sidebar, where System Settings shows the account.
private struct SettingsSidebarHeader: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("MissionStrike")
                    .font(.headline)
                Text("Version \(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }
}

/// A white symbol on a coloured rounded square, like the icons in System Settings' sidebar.
private struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

enum SettingsWindow {
    @MainActor
    static func make() -> NSWindow {
        let window = NSWindow()
        let controller = NSHostingController(rootView: SettingsView { [weak window] pane in
            window?.title = pane.title
        })
        controller.sceneBridgingOptions = [.toolbars]
        window.contentViewController = controller
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        // A toolbar gives the split view its inset sidebar and a place for the pane's title.
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
