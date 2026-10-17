@testable import MissionStrike
import Testing

@Suite("Close Feedback")
struct CloseFeedbackTests {

    @Test("A window that's gone closed, whether or not time is up")
    func closed() {
        #expect(CloseOutcome.decide(.gone, timedOut: false) == .closed)
        #expect(CloseOutcome.decide(.gone, timedOut: true) == .closed)
    }

    @Test("A sheet means the app asks first: no poof")
    func sheet() {
        #expect(CloseOutcome.decide(.open(hasSheet: true), timedOut: false) == .needsConfirmation)
        #expect(CloseOutcome.decide(.open(hasSheet: true), timedOut: true) == .needsConfirmation)
    }

    @Test("Still open without a sheet: wait, then call it a failure")
    func failed() {
        #expect(CloseOutcome.decide(.open(hasSheet: false), timedOut: false) == nil)
        #expect(CloseOutcome.decide(.open(hasSheet: false), timedOut: true) == .failed)
    }

    @Test("The confirmation badge names the app, and VoiceOver hears it too")
    func confirmationCopy() {
        let style = HoverBadgeStyle.needsConfirmation(appName: "TextEdit")
        #expect(style.label == "TextEdit asks before closing")
        #expect(style.announcement == "TextEdit asks before closing the window.")
        #expect(HoverBadgeStyle.needsConfirmation(appName: nil).label == "The app asks before closing")
        #expect(HoverBadgeStyle.close.announcement == nil)
        #expect(HoverBadgeStyle.failed.label == nil)
    }
}
