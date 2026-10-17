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
}
