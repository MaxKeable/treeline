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
        try store.save(projects)

        let loaded = store.load()
        #expect(loaded == projects)
    }

    @Test func missingFileReturnsEmpty() {
        let url = makeTempFileURL()
        let store = ProjectStore(fileURL: url)
        #expect(store.load().isEmpty)
    }

    @Test func emptyFileReturnsEmpty() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        #expect(store.load().isEmpty)
    }

    @Test func corruptFileReturnsEmpty() throws {
        let url = makeTempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not valid json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ProjectStore(fileURL: url)
        #expect(store.load().isEmpty)
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
          ]
        }
        """
        try Data(payload.utf8).write(to: url)

        let store = ProjectStore(fileURL: url)
        #expect(store.load().isEmpty)
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
        try store.save([project])

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(PersistedProjectState.self, from: data)
        #expect(decoded.schemaVersion == PersistedProjectState.currentSchemaVersion)
        #expect(decoded.projects == [project])
    }
}
