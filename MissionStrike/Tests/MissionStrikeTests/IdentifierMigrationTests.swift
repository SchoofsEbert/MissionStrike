import Foundation
@testable import MissionStrike
import Testing

@Suite("Identifier Migration")
struct IdentifierMigrationTests {

    /// Throwaway domains so the test never touches the real preferences.
    private func makeDomains() -> (defaults: UserDefaults, newName: String, legacyName: String) {
        let newName = "missionstrike.tests.new.\(UUID().uuidString)"
        let legacyName = "missionstrike.tests.legacy.\(UUID().uuidString)"
        return (UserDefaults(suiteName: newName)!, newName, legacyName)
    }

    @Test("Copies settings from the old identifier but restarts the setup guide")
    func copiesSettings() {
        let (defaults, newName, legacyName) = makeDomains()
        defer {
            defaults.removePersistentDomain(forName: newName)
            defaults.removePersistentDomain(forName: legacyName)
        }
        defaults.setPersistentDomain(
            ["leftClickModifier": "command", "poofOnClose": true, "hasLaunchedBefore": true,
             "accessibilityWasGranted": true, "NSWindow Frame Settings": "0 0 10 10"],
            forName: legacyName
        )

        IdentifierMigration.migrateIfNeeded(to: defaults, from: legacyName)

        #expect(defaults.string(forKey: "leftClickModifier") == "command")
        #expect(defaults.bool(forKey: "poofOnClose"))
        #expect(defaults.object(forKey: "hasLaunchedBefore") == nil)
        #expect(defaults.object(forKey: "accessibilityWasGranted") == nil)
        #expect(defaults.object(forKey: "NSWindow Frame Settings") == nil)
    }

    @Test("Leaves an already-used install alone")
    func skipsExistingInstall() {
        let (defaults, newName, legacyName) = makeDomains()
        defer {
            defaults.removePersistentDomain(forName: newName)
            defaults.removePersistentDomain(forName: legacyName)
        }
        defaults.set(true, forKey: "hasLaunchedBefore")
        defaults.set("option", forKey: "leftClickModifier")
        defaults.setPersistentDomain(["leftClickModifier": "command"], forName: legacyName)

        IdentifierMigration.migrateIfNeeded(to: defaults, from: legacyName)

        #expect(defaults.string(forKey: "leftClickModifier") == "option")
    }
}
