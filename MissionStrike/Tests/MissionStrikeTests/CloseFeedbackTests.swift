@testable import MissionStrike
import CoreGraphics
import Testing

/// Answers close-state checks from fixed windows, and counts what it's asked.
@MainActor
private final class FakeCloseEnvironment: CloseStateEnvironment {
    /// Window IDs still in the window list.
    var listed: Set<CGWindowID> = []
    /// Each app's windows (named by strings); nil for an app that can't be asked.
    var appWindows: [pid_t: [String]?] = [:]
    var windowIDs: [String: CGWindowID] = [:]
    var sheets: Set<String> = []

    private(set) var windowListCalls = 0
    private(set) var windowsAsked: [pid_t] = []
    private(set) var windowIDsAsked: [String] = []

    func listedWindowIDs(_ windowIDs: [CGWindowID]) -> Set<CGWindowID> {
        windowListCalls += 1
        return listed.intersection(windowIDs)
    }

    func windows(of pid: pid_t) -> [String]? {
        windowsAsked.append(pid)
        return appWindows[pid].flatMap { $0 }
    }

    func windowID(of window: String) -> CGWindowID? {
        windowIDsAsked.append(window)
        return windowIDs[window]
    }

    func hasSheet(_ window: String) -> Bool {
        sheets.contains(window)
    }
}

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

    @Test("A window gone from the window list is gone without asking its app")
    @MainActor
    func goneFromWindowList() {
        let environment = FakeCloseEnvironment()
        environment.appWindows = [7: ["a"]]
        environment.windowIDs = ["a": 1]
        let states = CloseStates.of([(7, 1, "a")], in: environment)
        #expect(states == [.gone])
        #expect(environment.windowsAsked.isEmpty)
    }

    @Test("Closes in one app ask it for its windows once, and each window for its ID once, as far as matching goes")
    @MainActor
    func oneAppAskedOnce() {
        let environment = FakeCloseEnvironment()
        environment.listed = [1, 2]
        environment.appWindows = [7: ["a", "b", "c"]]
        environment.windowIDs = ["a": 1, "b": 2, "c": 3]
        environment.sheets = ["b"]
        let states = CloseStates.of([(7, 1, "a"), (7, 2, "b")], in: environment)
        #expect(states == [.open(hasSheet: false), .open(hasSheet: true)])
        #expect(environment.windowListCalls == 1)
        #expect(environment.windowsAsked == [7])
        #expect(environment.windowIDsAsked == ["a", "b"])
    }

    @Test("A window without an ID is matched by its element, without asking any window for its ID")
    @MainActor
    func withoutWindowID() {
        let environment = FakeCloseEnvironment()
        environment.appWindows = [7: ["a", "b"]]
        environment.sheets = ["b"]
        #expect(CloseStates.of([(7, nil, "b")], in: environment) == [.open(hasSheet: true)])
        #expect(CloseStates.of([(7, nil, "z")], in: environment) == [.gone])
        #expect(environment.windowIDsAsked.isEmpty)
    }

    @Test("A window its app no longer lists is gone")
    @MainActor
    func droppedByApp() {
        let environment = FakeCloseEnvironment()
        environment.listed = [1]
        environment.appWindows = [7: ["b"]]
        environment.windowIDs = ["b": 2]
        #expect(CloseStates.of([(7, 1, "a")], in: environment) == [.gone])
    }

    @Test("An app that can't be asked is still open, and is asked only once")
    @MainActor
    func unanswered() {
        let environment = FakeCloseEnvironment()
        environment.listed = [1, 2]
        environment.appWindows = [7: nil]
        let states = CloseStates.of([(7, 1, "a"), (7, 2, "b")], in: environment)
        #expect(states == [.open(hasSheet: false), .open(hasSheet: false)])
        #expect(environment.windowsAsked == [7])
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
