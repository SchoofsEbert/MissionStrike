import AppKit
import ApplicationServices

// MARK: - Private API Declaration
// WARNING: _AXUIElementGetWindow is an undocumented Apple-private API.
// It maps an AXUIElement window to its CGWindowID. This is used as a fallback
// when the Accessibility tree alone cannot identify the correct window.
// Risk: may break in future macOS versions; guarantees App Store rejection.
// The fallback path degrades gracefully if this function fails.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

/// What hit-testing reads from an Accessibility element. `AXElement` is the live one;
/// tests build fake trees.
protocol AccessibilityElement: Hashable {
    var role: String? { get }
    var title: String? { get }
    /// Position and size in AX (top-left origin) space; nil when missing or degenerate.
    var frame: CGRect? { get }
    /// WindowManager's undocumented `wid`: the CGWindowID a Mission Control thumbnail shows.
    var thumbnailWindowID: CGWindowID? { get }
    var parent: Self? { get }
    var children: [Self] { get }
    func hasAction(_ action: String) -> Bool
}

/// An `AXUIElement` with typed accessors. Every Accessibility read in MissionStrike goes
/// through here.
struct AXElement: AccessibilityElement, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    static var systemWide: AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    static func application(_ pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    /// The element at a point in AX space, as seen system-wide.
    static func at(_ point: CGPoint) -> AXElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide.ref, Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return nil
        }
        return AXElement(element)
    }

    // MARK: - Attributes

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Several attributes in one round trip to the app; missing ones are left out.
    func attributes(_ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(ref, names as CFArray, AXCopyMultipleAttributeOptions(), &values) == .success,
              let values = values as [AnyObject]?, values.count == names.count else {
            return [:]
        }
        var result: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, values) where !Self.isMissing(value) {
            result[name] = value
        }
        return result
    }

    func string(_ name: String) -> String? {
        attribute(name) as? String
    }

    func element(_ name: String) -> AXElement? {
        Self.cast(attribute(name), AXUIElementGetTypeID(), as: AXUIElement.self).map(AXElement.init)
    }

    func elements(_ name: String) -> [AXElement]? {
        (attribute(name) as? [AXUIElement])?.map(AXElement.init)
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var parent: AXElement? { element(kAXParentAttribute) }
    var children: [AXElement] { elements(kAXChildrenAttribute) ?? [] }
    /// An app's windows; nil when the app can't be asked.
    var windows: [AXElement]? { elements(kAXWindowsAttribute) }
    var closeButton: AXElement? { element(kAXCloseButtonAttribute) }
    var url: URL? { (attribute(kAXURLAttribute) as? URL)?.standardizedFileURL }

    var frame: CGRect? {
        let values = attributes([kAXPositionAttribute, kAXSizeAttribute])
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = Self.cast(values[kAXPositionAttribute], AXValueGetTypeID(), as: AXValue.self),
              let extent = Self.cast(values[kAXSizeAttribute], AXValueGetTypeID(), as: AXValue.self),
              AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(extent, .cgSize, &size) else {
            return nil
        }
        let rect = CGRect(origin: origin, size: size)
        return rect.width > 1 && rect.height > 1 ? rect : nil
    }

    var thumbnailWindowID: CGWindowID? {
        guard let number = Self.cast(attribute("wid"), CFNumberGetTypeID(), as: CFNumber.self) else { return nil }
        var value: Int64 = 0
        guard CFNumberGetValue(number, .sInt64Type, &value), value > 0 else { return nil }
        return CGWindowID(value)
    }

    /// The CGWindowID behind a window element (private API).
    var windowID: CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(ref, &windowID) == .success else { return nil }
        return windowID
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(ref, &pid) == .success, pid != 0 else { return nil }
        return pid
    }

    // MARK: - Actions

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func hasAction(_ action: String) -> Bool {
        actionNames.contains(action)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(ref, action as CFString)
    }

    @discardableResult
    func set(_ attribute: String, to value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    // MARK: - Tree

    /// This element or its nearest ancestor with the given role, looking at most `limit` levels up.
    func ancestor(withRole role: String, limit: Int = .max) -> AXElement? {
        var current: AXElement? = self
        var depth = 0
        while let element = current, depth <= limit {
            if element.role == role { return element }
            current = element.parent
            depth += 1
        }
        return nil
    }

    // MARK: - CF casts

    /// CF types can't be checked with `as?`: compare the type ID, then cast.
    private static func cast<T>(_ value: CFTypeRef?, _ typeID: CFTypeID, as _: T.Type) -> T? {
        guard let value, CFGetTypeID(value) == typeID else { return nil }
        return (value as! T) // swiftlint:disable:this force_cast
    }

    /// Batched reads report a missing attribute as an AXError value (or null) in its slot.
    private static func isMissing(_ value: AnyObject) -> Bool {
        if CFGetTypeID(value) == CFNullGetTypeID() { return true }
        guard let axValue = cast(value, AXValueGetTypeID(), as: AXValue.self) else { return false }
        return AXValueGetType(axValue) == .axError
    }
}
