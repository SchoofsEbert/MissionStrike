@testable import MissionStrike
import CoreGraphics
import Testing

@MainActor
@Suite("Diagnostics Report")
struct DiagnosticsTests {

    @Test("Report includes the system, settings, the event tap and recorded events")
    func reportContents() {
        Diagnostics.shared.record("unit-test-click", at: CGPoint(x: 100, y: 100), resolution: nil)
        Diagnostics.shared.recordCallback(duration: .milliseconds(2))
        let report = Diagnostics.shared.report()
        #expect(report.contains("macOS "))
        #expect(report.contains("Settings: modifier="))
        #expect(report.contains("Event tap: "))
        #expect(report.contains("Mission Control windows"))
        #expect(report.contains("unit-test-click"))
    }

    @Test("Recorded input shows how long ago it happened, not the time of day")
    func relativeTimes() {
        #expect(Diagnostics.age(.milliseconds(4_200)) == "4s ago")
        #expect(Diagnostics.age(.seconds(125)) == "2m 5s ago")
        Diagnostics.shared.record("relative-time-click", at: .zero, resolution: nil)
        let line = Diagnostics.shared.report().split(separator: "\n").first { $0.contains("relative-time-click") }
        #expect(line?.contains("0s ago") == true)
    }

    @Test("Positions are rounded")
    func roundedPositions() {
        #expect(Diagnostics.format(CGPoint(x: 1234.4, y: 87)) == "(1240, 80)")
        #expect(Diagnostics.format(CGPoint(x: -9, y: 11)) == "(0, 20)")
    }
}
