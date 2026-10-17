import Foundation

/// Every user setting and its default. Defaults are registered from here and nowhere else.
enum SettingKey: String, CaseIterable, Sendable {
    case leftClickModifier
    case enableMiddleClick
    case enableContextMenu
    case enableKeyboardShortcuts
    case showHoverBadge
    case enableSpaceClosing
    case enableDockMiddleClick
    case poofOnClose
    case hapticFeedback
    case showMenuBarIcon
    case showWindowCounts

    /// The value used until the user changes the setting.
    var defaultValue: any Sendable {
        switch self {
        case .leftClickModifier: TriggerModifier.option.rawValue
        case .enableDockMiddleClick, .poofOnClose: false
        case .enableMiddleClick, .enableContextMenu, .enableKeyboardShortcuts, .showHoverBadge,
             .enableSpaceClosing, .hapticFeedback, .showMenuBarIcon, .showWindowCounts: true
        }
    }

    var defaultBool: Bool { defaultValue as? Bool ?? false }
    var defaultString: String { defaultValue as? String ?? "" }

    /// Short name in the diagnostics report.
    var diagnosticsName: String {
        switch self {
        case .leftClickModifier: "modifier"
        case .enableMiddleClick: "middleClick"
        case .enableContextMenu: "rightClickMenu"
        case .enableKeyboardShortcuts: "shortcuts"
        case .showHoverBadge: "hoverBadge"
        case .enableSpaceClosing: "spaces"
        case .enableDockMiddleClick: "dockMiddleClick"
        case .poofOnClose: "poof"
        case .hapticFeedback: "haptics"
        case .showMenuBarIcon: "menuBarIcon"
        case .showWindowCounts: "windowCounts"
        }
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultValue) }))
    }
}

extension UserDefaults {
    func bool(_ key: SettingKey) -> Bool {
        object(forKey: key.rawValue) as? Bool ?? key.defaultBool
    }

    func string(_ key: SettingKey) -> String {
        string(forKey: key.rawValue) ?? key.defaultString
    }
}

/// The user's settings at one moment.
struct Settings: Equatable, Sendable {
    /// Nil when the stored modifier is unknown: the left-click trigger is then off.
    var leftClickModifier: TriggerModifier?
    var enableMiddleClick: Bool
    var enableContextMenu: Bool
    var enableKeyboardShortcuts: Bool
    var showHoverBadge: Bool
    var enableSpaceClosing: Bool
    var enableDockMiddleClick: Bool
    var poofOnClose: Bool
    var hapticFeedback: Bool
    var showMenuBarIcon: Bool
    var showWindowCounts: Bool
}

extension Settings {
    /// Every setting at its default.
    static let defaults = Settings(
        leftClickModifier: TriggerModifier(rawValue: SettingKey.leftClickModifier.defaultString),
        enableMiddleClick: SettingKey.enableMiddleClick.defaultBool,
        enableContextMenu: SettingKey.enableContextMenu.defaultBool,
        enableKeyboardShortcuts: SettingKey.enableKeyboardShortcuts.defaultBool,
        showHoverBadge: SettingKey.showHoverBadge.defaultBool,
        enableSpaceClosing: SettingKey.enableSpaceClosing.defaultBool,
        enableDockMiddleClick: SettingKey.enableDockMiddleClick.defaultBool,
        poofOnClose: SettingKey.poofOnClose.defaultBool,
        hapticFeedback: SettingKey.hapticFeedback.defaultBool,
        showMenuBarIcon: SettingKey.showMenuBarIcon.defaultBool,
        showWindowCounts: SettingKey.showWindowCounts.defaultBool
    )

    init(_ defaults: UserDefaults) {
        leftClickModifier = TriggerModifier(rawValue: defaults.string(.leftClickModifier))
        enableMiddleClick = defaults.bool(.enableMiddleClick)
        enableContextMenu = defaults.bool(.enableContextMenu)
        enableKeyboardShortcuts = defaults.bool(.enableKeyboardShortcuts)
        showHoverBadge = defaults.bool(.showHoverBadge)
        enableSpaceClosing = defaults.bool(.enableSpaceClosing)
        enableDockMiddleClick = defaults.bool(.enableDockMiddleClick)
        poofOnClose = defaults.bool(.poofOnClose)
        hapticFeedback = defaults.bool(.hapticFeedback)
        showMenuBarIcon = defaults.bool(.showMenuBarIcon)
        showWindowCounts = defaults.bool(.showWindowCounts)
    }
}

/// The settings as the event tap and overlays read them: a snapshot, so the tap doesn't go
/// to UserDefaults on every event. Re-read whenever this process changes a default, which is
/// how the Settings window saves them.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var current = Settings(.standard)
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { SettingsStore.shared.reload() }
            } else {
                Task { @MainActor in SettingsStore.shared.reload() }
            }
        }
    }

    private func reload() {
        current = Settings(.standard)
    }
}
