import Foundation
import Testing
@testable import treeline

struct ProjectStoreTests {

    private func makeTempFileURL(_ label: String = #function) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("treeline-store-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
    }

    @Test func roundTripsProjectsThroughJSON() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        let projects = [
            Project(
                commonDirectoryPath: "/Users/dev/acme/.git",
                primaryCheckoutPath: "/Users/dev/acme",
                displayName: "acme"
            ),
            Project(
                commonDirectoryPath: "/Users/dev/widgets/.git",
                primaryCheckoutPath: "/Users/dev/widgets",
                displayName: "widgets"
            )
        ]
        try store.save(PersistedProjectState(projects: projects))

        let loaded = store.load()
        #expect(loaded.projects == projects)
        #expect(loaded.lastActiveProjectID == nil)
    }

    @Test func roundTripsLastActiveProjectID() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        let projects = [
            Project(
                commonDirectoryPath: "/Users/dev/acme/.git",
                primaryCheckoutPath: "/Users/dev/acme",
                displayName: "acme"
            )
        ]
        try store.save(
            PersistedProjectState(
                projects: projects,
                lastActiveProjectID: "/Users/dev/acme/.git"
            )
        )

        let loaded = store.load()
        #expect(loaded.projects == projects)
        #expect(loaded.lastActiveProjectID == "/Users/dev/acme/.git")
    }

    @Test func missingFileReturnsEmptyState() {
        let url = makeTempFileURL()
        let store = ProjectStore(fileURL: url)
        let loaded = store.load()
        #expect(loaded.projects.isEmpty)
        #expect(loaded.lastActiveProjectID == nil)
    }

    @Test func emptyFileReturnsEmptyState() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        let loaded = store.load()
        #expect(loaded.projects.isEmpty)
        #expect(loaded.lastActiveProjectID == nil)
    }

    @Test func corruptFileReturnsEmptyState() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not valid json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        let loaded = store.load()
        #expect(loaded.projects.isEmpty)
        #expect(loaded.lastActiveProjectID == nil)
    }

    @Test func futureSchemaVersionIsIgnored() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = """
        {
          "schemaVersion": 99,
          "projects": [
            {
              "commonDirectoryPath": "/x/.git",
              "primaryCheckoutPath": "/x",
              "displayName": "x"
            }
          ],
          "lastActiveProjectID": "/x/.git"
        }
        """
        try Data(payload.utf8).write(to: url)

        let store = ProjectStore(fileURL: url)
        let loaded = store.load()
        #expect(loaded.projects.isEmpty)
        #expect(loaded.lastActiveProjectID == nil)
    }

    @Test func legacyPayloadWithoutLastActiveDecodesCleanly() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let payload = """
        {
          "schemaVersion": 1,
          "projects": [
            {
              "commonDirectoryPath": "/x/.git",
              "primaryCheckoutPath": "/x",
              "displayName": "x"
            }
          ]
        }
        """
        try Data(payload.utf8).write(to: url)

        let store = ProjectStore(fileURL: url)
        let loaded = store.load()
        #expect(loaded.projects.count == 1)
        #expect(loaded.lastActiveProjectID == nil)
    }

    @Test func legacyPayloadBackfillsCheckoutPathsFromPrimary() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // v1 payload predates the `checkoutPaths` field. Decoding must
        // backfill it from `primaryCheckoutPath` so the invariant "primary
        // is always in the list" survives a load before the user attaches
        // anything new.
        let payload = """
        {
          "schemaVersion": 1,
          "projects": [
            {
              "commonDirectoryPath": "/x/.git",
              "primaryCheckoutPath": "/x",
              "displayName": "x"
            }
          ]
        }
        """
        try Data(payload.utf8).write(to: url)

        let loaded = ProjectStore(fileURL: url).load()
        #expect(loaded.projects.first?.checkoutPaths == ["/x"])
    }

    @Test func roundTripsCheckoutPaths() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme",
            checkoutPaths: ["/Users/dev/acme-wt", "/Users/dev/acme"]
        )
        try store.save(PersistedProjectState(projects: [project]))

        let loaded = store.load()
        #expect(loaded.projects.first?.checkoutPaths == ["/Users/dev/acme", "/Users/dev/acme-wt"])
    }

    @Test func currentSchemaVersionLoadsCleanly() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        let project = Project(
            commonDirectoryPath: "/x/.git",
            primaryCheckoutPath: "/x",
            displayName: "x"
        )
        try store.save(
            PersistedProjectState(projects: [project], lastActiveProjectID: project.id)
        )

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(PersistedProjectState.self, from: data)
        #expect(decoded.schemaVersion == PersistedProjectState.currentSchemaVersion)
        #expect(decoded.projects == [project])
        #expect(decoded.lastActiveProjectID == project.id)
    }
}
