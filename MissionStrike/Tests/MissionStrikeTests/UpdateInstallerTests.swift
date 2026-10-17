@testable import MissionStrike
import Foundation
import Testing

@Suite("Update Installation")
struct UpdateInstallerTests {

    /// A folder holding an "installed" app with a marker file, and a zip to install over it.
    private struct Fixture {
        let root: URL
        let installedApp: URL
        let marker: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
            installedApp = root.appendingPathComponent("Applications/MissionStrike.app")
            marker = installedApp.appendingPathComponent("Contents/marker")
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("installed".utf8).write(to: marker)
        }

        /// Zips a directory named `name` containing an unsigned stand-in bundle.
        func archive(containing name: String) throws -> URL {
            let source = root.appendingPathComponent("Source")
            let app = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true
            )
            let zip = root.appendingPathComponent("Update.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
            try ditto.run()
            ditto.waitUntilExit()
            return zip
        }

        var installedIsUntouched: Bool {
            (try? String(contentsOf: marker, encoding: .utf8)) == "installed"
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func install(_ zip: URL, over app: URL) async throws {
        _ = try await UpdateInstaller.install(
            from: zip,
            expectedVersion: "99.0.0",
            replacing: app,
            progress: { _ in },
            status: { _ in }
        )
    }

    @Test("An unsigned update is rejected and the installed app stays")
    func rejectsUnsignedUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let zip = try fixture.archive(containing: "MissionStrike.app")

        await #expect(throws: (any Error).self) {
            try await install(zip, over: fixture.installedApp)
        }
        #expect(fixture.installedIsUntouched)
    }

    @Test("An archive without MissionStrike.app is rejected")
    func rejectsArchiveWithoutApp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let zip = try fixture.archive(containing: "Other.app")

        await #expect {
            try await install(zip, over: fixture.installedApp)
        } throws: { error in
            if case UpdateError.missingAppBundle = error { true } else { false }
        }
        #expect(fixture.installedIsUntouched)
    }

    @Test("A location that isn't an app bundle is never replaced")
    func refusesNonBundleLocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let zip = try fixture.archive(containing: "MissionStrike.app")
        // Like `swift run`, where the "bundle" is the build folder.
        let buildFolder = fixture.installedApp.deletingLastPathComponent()

        await #expect {
            try await install(zip, over: buildFolder)
        } throws: { error in
            if case UpdateError.notReplaceable = error { true } else { false }
        }
        #expect(fixture.installedIsUntouched)
    }
}
