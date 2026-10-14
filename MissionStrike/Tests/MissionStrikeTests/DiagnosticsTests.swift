@testable import MissionStrike
import Testing

@Suite("Diagnostics Report")
struct DiagnosticsTests {

    @Test("Report includes the system, settings and recorded events")
    func reportContents() {
        Diagnostics.shared.record("unit-test-click", resolution: nil)
        let report = Diagnostics.shared.report()
        #expect(report.contains("macOS "))
        #expect(report.contains("Settings: modifier="))
        #expect(report.contains("Mission Control windows"))
        #expect(report.contains("unit-test-click"))
    }
}
