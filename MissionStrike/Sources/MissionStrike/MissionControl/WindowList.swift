import CoreGraphics

/// Looks up app windows in the CoreGraphics window list.
enum WindowList {
    /// The app window with this CGWindowID, or nil when it's gone or belongs to the system
    /// (Dock, WindowManager, …).
    static func appWindow(withID windowID: CGWindowID) -> AppWindow? {
        // Describes just this window (on screen or not) instead of copying the whole list.
        var ids = [UnsafeRawPointer(bitPattern: UInt(windowID))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else {
            return nil
        }
        return appWindow(withID: windowID, in: list)
    }

    /// The app window with this CGWindowID in a window list (as `CGWindowListCopyWindowInfo`
    /// returns it), skipping system owners.
    static func appWindow(
        withID windowID: CGWindowID,
        in windowList: [[String: Any]],
        ignoredOwners: Set<String> = MissionStrikeConfig.default.ignoredWindowOwners
    ) -> AppWindow? {
        for info in windowList {
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            guard id == windowID else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
            guard !owner.isEmpty, !ignoredOwners.contains(owner), pid != 0 else { return nil }
            return AppWindow(pid: pid, ownerName: owner, windowID: windowID)
        }
        return nil
    }

    /// Windows smaller than this are helpers and status items, not something to look at.
    private static let minimumVisibleSize: CGFloat = 50

    /// Which apps own any window at all (minimized, hidden or on another Space included), and
    /// which have a normal window on screen, from one copy of the window list.
    static func ownership() -> (owning: Set<pid_t>, showing: Set<pid_t>) {
        ownership(in: CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    static func ownership(in windowList: [[String: Any]]) -> (owning: Set<pid_t>, showing: Set<pid_t>) {
        var owning: Set<pid_t> = []
        var showing: Set<pid_t> = []
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != 0 else { continue }
            owning.insert(pid)
            guard info[kCGWindowIsOnscreen as String] as? Bool == true,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minimumVisibleSize, bounds.height >= minimumVisibleSize else {
                continue
            }
            showing.insert(pid)
        }
        return (owning, showing)
    }
}
