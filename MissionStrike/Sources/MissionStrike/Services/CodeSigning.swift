import Foundation
import Security

/// Code signing identity shared by every MissionStrike release.
///
/// Releases are signed with a self-signed certificate (no paid Apple Developer account).
/// Its stable designated requirement lets macOS keep the Accessibility grant across
/// updates, and lets the updater reject archives not signed with the same key.
enum CodeSigning {
    /// Designated requirement of release builds. `scripts/package-app.sh` reads this line,
    /// and `install.sh` repeats it; keep all three in sync if the certificate ever changes.
    static let requirement = #"identifier "com.vibecoded.missionstrike" and certificate leaf = H"4db8f2724be711f4ad297925bac86fb1a77e8037""#

    /// Whether the bundle at `url` has a valid signature that satisfies ``requirement``.
    static func isTrustedRelease(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(staticCode, flags, secRequirement) == errSecSuccess
    }

    /// Throws unless the bundle is a trusted release with exactly `expectedVersion`, so an
    /// unsigned archive or an older signed release cannot be installed as an update.
    static func verifyUpdate(at url: URL, expectedVersion: String) throws {
        guard isTrustedRelease(at: url) else {
            throw NSError(
                domain: "UpdateChecker", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The downloaded update is not signed by MissionStrike."]
            )
        }
        let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expectedVersion else {
            throw NSError(
                domain: "UpdateChecker", code: 4,
                userInfo: [NSLocalizedDescriptionKey:
                    "The downloaded update has version \(version ?? "unknown"), expected \(expectedVersion)."]
            )
        }
    }
}
