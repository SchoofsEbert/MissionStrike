import Foundation

/// Carries settings over from the old bundle identifier (`com.vibecoded.missionstrike`,
/// used up to 2.6.1) the first time the renamed app launches.
enum IdentifierMigration {
    static let legacyIdentifier = "com.vibecoded.missionstrike"

    /// Keys left behind so the renamed app starts fresh where it must: macOS treats it
    /// as a new app, so Accessibility has to be granted again and the setup guide
    /// should walk through that.
    private static let skippedKeys: Set<String> = ["hasLaunchedBefore", "accessibilityWasGranted"]
    private static let migratedKey = "migratedFromLegacyIdentifier"

    static func migrateIfNeeded(to defaults: UserDefaults = .standard, from legacyDomain: String = legacyIdentifier) {
        guard !defaults.bool(forKey: migratedKey),
              defaults.object(forKey: "hasLaunchedBefore") == nil,
              let legacy = defaults.persistentDomain(forName: legacyDomain) else {
            return
        }
        for (key, value) in legacy where !skippedKeys.contains(key) && !key.hasPrefix("NS") {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
