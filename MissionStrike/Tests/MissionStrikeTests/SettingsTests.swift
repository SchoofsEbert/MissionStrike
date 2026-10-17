@testable import MissionStrike
import Foundation
import Testing

@Suite("Settings")
struct SettingsTests {

    /// A throwaway defaults domain, removed after the test.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "MissionStrikeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Could not create a defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("Unset settings fall back to SettingKey's defaults")
    func fallbacks() {
        withDefaults { defaults in
            let settings = Settings(defaults)
            #expect(settings.leftClickModifier == .option)
            #expect(settings.enableMiddleClick)
            #expect(settings.enableSpaceClosing)
            #expect(!settings.enableDockMiddleClick)
            #expect(!settings.poofOnClose)
            #expect(settings.hapticFeedback)
            #expect(settings.showWindowCounts)
            #expect(settings.enableKeyboardHints)
            #expect(settings.showCheatSheet)
            #expect(settings.showFirstRunHint)
        }
    }

    @Test("Registered defaults read the same as the fallbacks")
    func registeredDefaults() {
        withDefaults { registered in
            SettingKey.registerDefaults(in: registered)
            withDefaults { unregistered in
                #expect(Settings(registered) == Settings(unregistered))
            }
        }
    }

    @Test("Stored values win, and an unknown modifier turns the left-click trigger off")
    func storedValues() {
        withDefaults { defaults in
            SettingKey.registerDefaults(in: defaults)
            defaults.set(false, forKey: SettingKey.enableMiddleClick.rawValue)
            defaults.set(TriggerModifier.control.rawValue, forKey: SettingKey.leftClickModifier.rawValue)
            #expect(!Settings(defaults).enableMiddleClick)
            #expect(Settings(defaults).leftClickModifier == .control)

            defaults.set("hyper", forKey: SettingKey.leftClickModifier.rawValue)
            #expect(Settings(defaults).leftClickModifier == nil)
        }
    }

    @Test("Every setting has its own diagnostics name")
    func diagnosticsNames() {
        let names = SettingKey.allCases.map(\.diagnosticsName)
        #expect(Set(names).count == names.count)
    }
}
