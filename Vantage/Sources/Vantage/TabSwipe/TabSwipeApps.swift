/// Which apps tab swipes work in.
enum TabSwipeAppScope: String, CaseIterable, Identifiable, Sendable {
    case allApps
    case onlyListed
    case allExceptListed

    var id: Self { self }

    var title: String {
        switch self {
        case .allApps: "All Apps"
        case .onlyListed: "Only These Apps"
        case .allExceptListed: "All Apps Except These"
        }
    }
}

struct TabSwipeApps: Equatable, Sendable {
    var scope: TabSwipeAppScope
    var bundleIDs: Set<String>

    /// Whether a swipe switches tabs in the app in front. An app without a bundle ID can't be
    /// listed, so it only counts under All Apps and All Apps Except These.
    func allows(_ bundleID: String?) -> Bool {
        switch scope {
        case .allApps: true
        case .onlyListed: bundleID.map(bundleIDs.contains) ?? false
        case .allExceptListed: !(bundleID.map(bundleIDs.contains) ?? false)
        }
    }
}
