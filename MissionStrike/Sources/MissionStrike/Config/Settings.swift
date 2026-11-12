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
    case enableKeyboardHints
    case showCheatSheet
    case showFirstRunHint
    case enableTabSwipe
    case tabSwipeHaptics
    case tabSwipeAppScope
    case tabSwipeApps
    case enableWindowSnapping
    case enableSnapAssist
    case snapLeftShortcut
    case snapRightShortcut
    case snapTopShortcut
    case snapBottomShortcut
    case snapMaximizeShortcut
    case snapNextDisplayShortcut
    case snapPreviousDisplayShortcut

    /// The value used until the user changes the setting.
    var defaultValue: any Sendable {
        switch self {
        case .leftClickModifier: TriggerModifier.option.rawValue
        case .tabSwipeAppScope: TabSwipeAppScope.allApps.rawValue
        case .tabSwipeApps: [String]()
        case .snapLeftShortcut, .snapRightShortcut, .snapTopShortcut, .snapBottomShortcut, .snapMaximizeShortcut,
             .snapNextDisplayShortcut, .snapPreviousDisplayShortcut:
            snapAction.flatMap { SnapShortcuts.defaults[$0]?.storage } ?? ""
        case .enableDockMiddleClick, .poofOnClose, .enableTabSwipe, .enableWindowSnapping: false
        case .enableMiddleClick, .enableContextMenu, .enableKeyboardShortcuts, .showHoverBadge,
             .enableSpaceClosing, .hapticFeedback, .showMenuBarIcon, .showWindowCounts,
             .enableKeyboardHints, .showCheatSheet, .showFirstRunHint, .tabSwipeHaptics, .enableSnapAssist: true
        }
    }

    var defaultBool: Bool { defaultValue as? Bool ?? false }
    var defaultString: String { defaultValue as? String ?? "" }
    var defaultStrings: [String] { defaultValue as? [String] ?? [] }

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
        case .enableKeyboardHints: "keyboardHints"
        case .showCheatSheet: "cheatSheet"
        case .showFirstRunHint: "firstRunHint"
        case .enableTabSwipe: "tabSwipe"
        case .tabSwipeHaptics: "tabSwipeHaptics"
        case .tabSwipeAppScope: "tabSwipeScope"
        case .tabSwipeApps: "tabSwipeApps"
        case .enableWindowSnapping: "snapping"
        case .enableSnapAssist: "snapAssist"
        case .snapLeftShortcut: "snapLeft"
        case .snapRightShortcut: "snapRight"
        case .snapTopShortcut: "snapTop"
        case .snapBottomShortcut: "snapBottom"
        case .snapMaximizeShortcut: "snapMaximize"
        case .snapNextDisplayShortcut: "snapNextDisplay"
        case .snapPreviousDisplayShortcut: "snapPreviousDisplay"
        }
    }

    /// The snap action whose shortcut this setting holds.
    var snapAction: SnapAction? {
        switch self {
        case .snapLeftShortcut: .left
        case .snapRightShortcut: .right
        case .snapTopShortcut: .top
        case .snapBottomShortcut: .bottom
        case .snapMaximizeShortcut: .maximize
        case .snapNextDisplayShortcut: .nextDisplay
        case .snapPreviousDisplayShortcut: .previousDisplay
        default: nil
        }
    }

    static func snapShortcut(for action: SnapAction) -> SettingKey {
        switch action {
        case .left: .snapLeftShortcut
        case .right: .snapRightShortcut
        case .top: .snapTopShortcut
        case .bottom: .snapBottomShortcut
        case .maximize: .snapMaximizeShortcut
        case .nextDisplay: .snapNextDisplayShortcut
        case .previousDisplay: .snapPreviousDisplayShortcut
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

    func strings(_ key: SettingKey) -> [String] {
        stringArray(forKey: key.rawValue) ?? key.defaultStrings
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
    var enableKeyboardHints: Bool
    var showCheatSheet: Bool
    var showFirstRunHint: Bool
    var enableTabSwipe: Bool
    var tabSwipeHaptics: Bool
    var tabSwipeApps: TabSwipeApps
    /// Empty while snapping is off.
    var snapShortcuts: SnapShortcuts
    var enableSnapAssist: Bool
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
        showWindowCounts: SettingKey.showWindowCounts.defaultBool,
        enableKeyboardHints: SettingKey.enableKeyboardHints.defaultBool,
        showCheatSheet: SettingKey.showCheatSheet.defaultBool,
        showFirstRunHint: SettingKey.showFirstRunHint.defaultBool,
        enableTabSwipe: SettingKey.enableTabSwipe.defaultBool,
        tabSwipeHaptics: SettingKey.tabSwipeHaptics.defaultBool,
        tabSwipeApps: TabSwipeApps(scope: .allApps, bundleIDs: []),
        snapShortcuts: SnapShortcuts(),
        enableSnapAssist: SettingKey.enableSnapAssist.defaultBool
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
        enableKeyboardHints = defaults.bool(.enableKeyboardHints)
        showCheatSheet = defaults.bool(.showCheatSheet)
        showFirstRunHint = defaults.bool(.showFirstRunHint)
        enableTabSwipe = defaults.bool(.enableTabSwipe)
        tabSwipeHaptics = defaults.bool(.tabSwipeHaptics)
        tabSwipeApps = TabSwipeApps(
            scope: TabSwipeAppScope(rawValue: defaults.string(.tabSwipeAppScope)) ?? .allApps,
            bundleIDs: Set(defaults.strings(.tabSwipeApps))
        )
        snapShortcuts = defaults.bool(.enableWindowSnapping)
            ? SnapShortcuts(SnapAction.allCases.reduce(into: [:]) { shortcuts, action in
                shortcuts[action] = KeyShortcut(storage: defaults.string(SettingKey.snapShortcut(for: action)))
            })
            : SnapShortcuts()
        enableSnapAssist = defaults.bool(.enableSnapAssist)
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
