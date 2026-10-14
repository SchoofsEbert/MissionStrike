@testable import MissionStrike
import Foundation
import Security
import Testing

@Suite("Update Signature Verification")
struct CodeSigningTests {

    @Test("Release requirement string is valid")
    func requirementParses() {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(CodeSigning.requirement as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test("Bundles not signed with the release certificate are rejected")
    func rejectsForeignSignature() throws {
        // System apps are validly signed, just not by MissionStrike's certificate.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(!CodeSigning.isTrustedRelease(at: calculator))
        #expect(throws: (any Error).self) {
            try CodeSigning.verifyUpdate(at: calculator, expectedVersion: "99.0.0")
        }
    }

    @Test("Missing bundles are rejected")
    func rejectsMissingBundle() {
        let missing = URL(fileURLWithPath: "/nonexistent/MissionStrike.app")
        #expect(!CodeSigning.isTrustedRelease(at: missing))
    }
}
