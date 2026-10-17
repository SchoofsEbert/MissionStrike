@testable import MissionStrike
import Testing

@Suite("Release Version Parsing")
struct ReleaseVersionTests {

    @Test("Only a single leading v is removed from release tags")
    func stripsOnlyLeadingV() {
        #expect(ReleaseVersion.fromTag("v2.8.0") == "2.8.0")
        #expect(ReleaseVersion.fromTag("2.8.0") == "2.8.0")
        #expect(ReleaseVersion.fromTag(" v2.8.0\n") == "2.8.0")
        #expect(ReleaseVersion.fromTag("v2.9.0-dev") == "2.9.0-dev")
        #expect(ReleaseVersion.fromTag("vv2.8.0") == nil)
    }

    @Test("Tags without a version are rejected")
    func rejectsInvalidTags() {
        #expect(ReleaseVersion.fromTag("") == nil)
        #expect(ReleaseVersion.fromTag("  ") == nil)
        #expect(ReleaseVersion.fromTag("v") == nil)
        #expect(ReleaseVersion.fromTag("latest") == nil)
        #expect(ReleaseVersion.fromTag("v2..0") == nil)
    }

    @Test("Versions compare numerically, component by component")
    func comparesVersions() {
        #expect(ReleaseVersion.isNewer("2.9.0", than: "2.8.9"))
        #expect(ReleaseVersion.isNewer("2.10.0", than: "2.9.1"))
        #expect(ReleaseVersion.isNewer("3.0", than: "2.99.99"))
        #expect(ReleaseVersion.isNewer("2.8.1", than: "2.8"))
        #expect(!ReleaseVersion.isNewer("2.8.0", than: "2.8.0"))
        #expect(!ReleaseVersion.isNewer("2.8", than: "2.8.0"))
        #expect(!ReleaseVersion.isNewer("2.7.9", than: "2.8.0"))
    }

    @Test("Unparseable versions are never newer")
    func ignoresUnparseableVersions() {
        #expect(!ReleaseVersion.isNewer("not-a-version", than: "2.8.0"))
        #expect(!ReleaseVersion.isNewer("9.0.0", than: "unknown"))
    }

    @Test("A suffix doesn't make a version newer than its release")
    func ignoresSuffixes() {
        #expect(!ReleaseVersion.isNewer("2.9.0-beta", than: "2.9.0"))
        #expect(ReleaseVersion.isNewer("2.9.0-beta", than: "2.8.0"))
    }
}
