import AppKit
import SwiftUI

/// The tabs of the Settings window, in toolbar order.
enum SettingsPane: String, CaseIterable {
    case general
    case missionControl
    case feedback
    case dock

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
        case .general: "gearshape"
        case .missionControl: "rectangle.3.group"
        case .feedback: "sparkles"
        case .dock: "dock.rectangle"
        }
    }

    @MainActor
    var content: AnyView {
        switch self {
        case .general: AnyView(GeneralSettingsPane())
        case .missionControl: AnyView(MissionControlSettingsPane())
        case .feedback: AnyView(FeedbackSettingsPane())
        case .dock: AnyView(DockSettingsPane())
        }
    }
}

enum SettingsWindow {
    static let width: CGFloat = 480

    /// A preferences-style window with a toolbar tab per pane. The window resizes to each pane.
    @MainActor
    static func make() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let controller = NSHostingController(rootView: pane.content)
            controller.sizingOptions = .preferredContentSize
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

extension View {
    /// Lays a settings pane out as a grouped form of the window's width and the given height.
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: SettingsWindow.width, height: height)
    }
}
