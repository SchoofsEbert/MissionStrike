import CoreGraphics
import Foundation

/// Looks up app windows in the CoreGraphics window list.
enum WindowList {
    /// The app window with this CGWindowID, or nil when it's gone or belongs to the system
    /// (Dock, WindowManager, …). With `onScreenOnly`, also nil when it isn't on screen, such as
    /// a window on another Space.
    static func appWindow(withID windowID: CGWindowID, onScreenOnly: Bool = false) -> AppWindow? {
        // Describes just this window (on screen or not) instead of copying the whole list.
        var ids = [UnsafeRawPointer(bitPattern: UInt(windowID))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else {
            return nil
        }
        return appWindow(withID: windowID, in: list, onScreenOnly: onScreenOnly)
    }

    /// The app window with this CGWindowID in a window list (as `CGWindowListCopyWindowInfo`
    /// returns it), skipping system owners.
    static func appWindow(
        withID windowID: CGWindowID,
        in windowList: [[String: Any]],
        ignoredOwners: Set<String> = MissionStrikeConfig.default.ignoredWindowOwners,
        onScreenOnly: Bool = false
    ) -> AppWindow? {
        for info in windowList {
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            guard id == windowID else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            guard !owner.isEmpty, !ignoredOwners.contains(owner), pid != 0,
                  !onScreenOnly || isOnScreen(info) else { return nil }
            return AppWindow(pid: pid, ownerName: owner, windowID: windowID)
        }
        return nil
    }

    /// The app windows among these CGWindowIDs, from one window-list call; system windows are
    /// left out, and with `onScreenOnly` so are windows that aren't on screen.
    static func appWindows(withIDs windowIDs: [CGWindowID], onScreenOnly: Bool = false) -> [CGWindowID: AppWindow] {
        guard !windowIDs.isEmpty else { return [:] }
        var ids = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else {
            return [:]
        }
        return appWindows(in: list, onScreenOnly: onScreenOnly)
    }

    /// Every app window in a window list by CGWindowID, skipping system owners.
    static func appWindows(
        in windowList: [[String: Any]],
        ignoredOwners: Set<String> = MissionStrikeConfig.default.ignoredWindowOwners,
        onScreenOnly: Bool = false
    ) -> [CGWindowID: AppWindow] {
        var windows: [CGWindowID: AppWindow] = [:]
        for info in windowList {
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            guard id != 0, !owner.isEmpty, !ignoredOwners.contains(owner), pid != 0,
                  !onScreenOnly || isOnScreen(info) else { continue }
            windows[id] = AppWindow(pid: pid, ownerName: owner, windowID: id)
        }
        return windows
    }

    private static func isOnScreen(_ info: [String: Any]) -> Bool {
        info[kCGWindowIsOnscreen as String] as? Bool == true
    }

    /// Windows smaller than this are helpers and status items, not something to look at.
    private static let minimumVisibleSize: CGFloat = 50

    /// Which apps own any window at all (helpers and status items included), and which have a
    /// normal window: on screen, minimized or on another Space. From one copy of the window list.
    static func ownership() -> (owning: Set<pid_t>, showing: Set<pid_t>) {
        ownership(in: CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    /// - Parameter isOnSpace: Whether a window off screen belongs to a Space, as minimized windows
    ///   and those on other Spaces do; the invisible windows apps keep around belong to none.
    static func ownership(
        in windowList: [[String: Any]],
        isOnSpace: (CGWindowID) -> Bool = isOnSpace
    ) -> (owning: Set<pid_t>, showing: Set<pid_t>) {
        var owning: Set<pid_t> = []
        var showing: Set<pid_t> = []
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != 0 else { continue }
            owning.insert(pid)
            guard !showing.contains(pid),
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minimumVisibleSize, bounds.height >= minimumVisibleSize else {
                continue
            }
            // Accessibility only lists the windows on the current Space, so a window elsewhere
            // has to be found here or its app looks windowless.
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            guard isOnScreen(info) || (id != 0 && isOnSpace(id)) else { continue }
            showing.insert(pid)
        }
        return (owning, showing)
    }

    /// Whether the window belongs to any Space (private API).
    static func isOnSpace(_ windowID: CGWindowID) -> Bool {
        let ids = [NSNumber(value: windowID)] as CFArray
        let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), allSpacesMask, ids)?.takeRetainedValue() as? [Any]
        return spaces?.isEmpty == false
    }

    /// Current, other and fullscreen Spaces.
    private static let allSpacesMask: Int32 = 7
}

// WARNING: Apple-private SkyLight calls, used only to tell windows on other Spaces from the
// invisible windows apps keep. If they go away, apps whose only windows are on another Space
// look windowless again, as before.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?
