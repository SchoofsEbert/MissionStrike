import Carbon.HIToolbox
import CoreGraphics

/// A key with modifiers, as a global shortcut. Stored in the defaults as `keyCode:modifiers`.
struct KeyShortcut: Hashable, Sendable {
    let keyCode: Int64
    /// Raw `CGEventFlags`, reduced to ⌘ ⌥ ⌃ ⇧.
    let modifiers: UInt64

    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    init(keyCode: Int64, flags: CGEventFlags) {
        self.keyCode = keyCode
        modifiers = flags.intersection(Self.modifierMask).rawValue
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let keyCode = Int64(parts[0]), let modifiers = UInt64(parts[1]) else { return nil }
        self.init(keyCode: keyCode, flags: CGEventFlags(rawValue: modifiers))
    }

    var storage: String { "\(keyCode):\(modifiers)" }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// A shortcut must not take a key away from typing: it needs ⌘, ⌥ or ⌃, unless it's a
    /// function key.
    var isAllowed: Bool {
        !flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl]) || Self.functionKeys[Int(keyCode)] != nil
    }

    private static let functionKeys: [Int: String] = {
        let codes = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, "F\($0 + 1)") })
    }()

    /// As menus show it, such as ⌃⌥←.
    var displayString: String {
        var text = ""
        if flags.contains(.maskControl) { text += "⌃" }
        if flags.contains(.maskAlternate) { text += "⌥" }
        if flags.contains(.maskShift) { text += "⇧" }
        if flags.contains(.maskCommand) { text += "⌘" }
        return text + Self.keyName(Int(keyCode))
    }

    private static func keyName(_ keyCode: Int) -> String {
        if let name = specialKeyNames[keyCode] ?? functionKeys[keyCode] { return name }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟"
    ]

    /// What the key types on the current keyboard layout, without modifiers.
    private static func layoutCharacter(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// The snap shortcuts the tap looks keys up in. Empty while snapping is off.
struct SnapShortcuts: Equatable, Sendable {
    private var actions: [KeyShortcut: SnapAction] = [:]

    init(_ shortcuts: [SnapAction: KeyShortcut] = [:]) {
        for (action, shortcut) in shortcuts {
            actions[shortcut] = action
        }
    }

    var isEmpty: Bool { actions.isEmpty }

    func action(keyCode: Int64, flags: CGEventFlags) -> SnapAction? {
        guard !actions.isEmpty else { return nil }
        return actions[KeyShortcut(keyCode: keyCode, flags: flags)]
    }

    /// Like Rectangle's: ⌃⌥ and an arrow for the sides, ⌃⌥↩ to fill the screen, ⇧ to change screens.
    static let defaults: [SnapAction: KeyShortcut] = [
        .left: KeyShortcut(keyCode: Int64(kVK_LeftArrow), flags: [.maskControl, .maskAlternate]),
        .right: KeyShortcut(keyCode: Int64(kVK_RightArrow), flags: [.maskControl, .maskAlternate]),
        .top: KeyShortcut(keyCode: Int64(kVK_UpArrow), flags: [.maskControl, .maskAlternate]),
        .bottom: KeyShortcut(keyCode: Int64(kVK_DownArrow), flags: [.maskControl, .maskAlternate]),
        .maximize: KeyShortcut(keyCode: Int64(kVK_Return), flags: [.maskControl, .maskAlternate]),
        .nextDisplay: KeyShortcut(keyCode: Int64(kVK_RightArrow), flags: [.maskControl, .maskAlternate, .maskShift]),
        .previousDisplay: KeyShortcut(keyCode: Int64(kVK_LeftArrow), flags: [.maskControl, .maskAlternate, .maskShift])
    ]
}
