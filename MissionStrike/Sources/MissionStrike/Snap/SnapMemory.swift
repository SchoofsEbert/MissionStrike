import CoreGraphics

/// What snapping remembers per window: its last snap, for cycling, and where it was before
/// MissionStrike first moved it, for Restore. The snapper keeps one on its queue.
struct SnapMemory {
    /// Past this many windows, those that are gone are dropped, then the least recently snapped.
    static let capacity = 64

    private(set) var records: [CGWindowID: SnapRecord] = [:]
    private(set) var restoreFrames: [CGWindowID: CGRect] = [:]
    /// When each window was last snapped, as a count of snaps.
    private var lastUsed: [CGWindowID: Int] = [:]
    private var uses = 0

    func record(for windowID: CGWindowID?) -> SnapRecord? {
        windowID.flatMap { records[$0] }
    }

    /// Whether MissionStrike put the window where it is: then where it was before still holds.
    func placedHere(_ windowID: CGWindowID, frame: CGRect) -> Bool {
        records[windowID].map { SnapLayout.isClose($0.frame, frame) } ?? false
    }

    /// Before MissionStrike moves a window from `frame`: keeps that frame for Restore, unless
    /// MissionStrike put it there, so a window snapped again and again restores to where it was
    /// before the first snap.
    mutating func willMove(_ windowID: CGWindowID, from frame: CGRect, liveWindows: () -> Set<CGWindowID>) {
        guard !placedHere(windowID, frame: frame) else { return }
        makeRoom(for: windowID, liveWindows)
        restoreFrames[windowID] = frame
    }

    mutating func didMove(_ windowID: CGWindowID, _ record: SnapRecord, liveWindows: () -> Set<CGWindowID>) {
        makeRoom(for: windowID, liveWindows)
        records[windowID] = record
    }

    /// Whether filling the screen means Restore instead: the window already fills it, or
    /// MissionStrike filled it and it hasn't moved (apps like Terminal don't fill it exactly).
    func fillRestores(_ windowID: CGWindowID, current: CGRect, areas: [CGRect]) -> Bool {
        guard restoreFrames[windowID] != nil else { return false }
        if let area = SnapLayout.area(for: current, in: areas), SnapLayout.isClose(area, current) { return true }
        guard let record = records[windowID] else { return false }
        return record.action == .maximize && SnapLayout.isClose(record.frame, current)
    }

    /// Takes the frame to restore to. When the screen it was on is gone, the window keeps its
    /// size, as far as it fits, in the middle of the screen it's on now.
    mutating func takeRestore(_ windowID: CGWindowID, current: CGRect, areas: [CGRect]) -> CGRect? {
        guard let frame = restoreFrames.removeValue(forKey: windowID) else { return nil }
        records[windowID] = nil
        if areas.contains(where: { $0.intersects(frame) }) { return frame }
        guard let area = SnapLayout.area(for: current, in: areas) else { return nil }
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Marks the window as just used. Before a new window is added at capacity, drops the windows
    /// that are gone, then the least recently snapped.
    private mutating func makeRoom(for windowID: CGWindowID, _ liveWindows: () -> Set<CGWindowID>) {
        uses += 1
        defer { lastUsed[windowID] = uses }
        guard lastUsed[windowID] == nil, lastUsed.count >= Self.capacity else { return }
        let alive = liveWindows()
        var known = Set(lastUsed.keys.filter(alive.contains))
        while known.count >= Self.capacity, let oldest = known.min(by: { lastUsed[$0, default: 0] < lastUsed[$1, default: 0] }) {
            known.remove(oldest)
        }
        records = records.filter { known.contains($0.key) }
        restoreFrames = restoreFrames.filter { known.contains($0.key) }
        lastUsed = lastUsed.filter { known.contains($0.key) }
    }
}
