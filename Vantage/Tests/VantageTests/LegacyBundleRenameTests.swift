import Foundation
@testable import Vantage
import Testing

@Suite("Legacy Bundle Rename")
struct LegacyBundleRenameTests {

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyBundleRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("Moves MissionStrike.app to Vantage.app beside it")
    func renamesLegacyBundle() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = LegacyBundleRename.destination(for: folder.appendingPathComponent("MissionStrike.app"))

        #expect(destination == folder.appendingPathComponent("Vantage.app"))
    }

    @Test("Leaves a bundle already named Vantage.app alone")
    func ignoresNewName() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(LegacyBundleRename.destination(for: folder.appendingPathComponent("Vantage.app")) == nil)
    }

    @Test("Doesn't overwrite an existing Vantage.app")
    func keepsExistingVantage() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Vantage.app"), withIntermediateDirectories: true
        )

        #expect(LegacyBundleRename.destination(for: folder.appendingPathComponent("MissionStrike.app")) == nil)
    }
}
