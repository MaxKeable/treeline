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

    // MARK: - Storage boundary

    /// Allowed top-level keys for the persisted JSON state. Anything else is a
    /// regression of the non-secret storage boundary documented on
    /// `PersistedProjectState` — at minimum it has to be added to this list
    /// (with a teammate review of why it's safe to write to disk in plain JSON).
    private static let allowedRootKeys: Set<String> = [
        "schemaVersion",
        "projects",
        "lastActiveProjectID"
    ]

    /// Allowed per-Project keys. Same contract: any new field gets here only
    /// after we've confirmed it is non-secret (Project identity, display data,
    /// or already-public GitHub repo metadata like owner/name).
    private static let allowedProjectKeys: Set<String> = [
        "commonDirectoryPath",
        "primaryCheckoutPath",
        "displayName",
        "checkoutPaths"
    ]

    /// Substrings that would indicate someone added a secret-shaped field to
    /// persisted state. The list mirrors the categories called out in the
    /// `PersistedProjectState` doc comment: API keys, OAuth/PAT tokens, gh
    /// credentials, future AI provider secrets, generic password material.
    /// Case-insensitive — Swift `Codable` keys are JSON-cased verbatim, but
    /// this guards both `apiKey` and `api_key` shapes.
    private static let secretLikeKeySubstrings: [String] = [
        "apikey",
        "api_key",
        "secret",
        "password",
        "passwd",
        "token",
        "bearer",
        "credential",
        "privatekey",
        "private_key",
        "clientsecret",
        "client_secret",
        "refreshtoken",
        "refresh_token",
        "accesstoken",
        "access_token",
        "ghtoken",
        "gh_token"
    ]

    @Test func persistedStateUsesOnlyAllowlistedTopLevelKeys() throws {
        let project = Project(
            commonDirectoryPath: "/x/.git",
            primaryCheckoutPath: "/x",
            displayName: "x"
        )
        let state = PersistedProjectState(projects: [project], lastActiveProjectID: project.id)

        let data = try JSONEncoder().encode(state)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let rootKeys = Set(object.keys)
        #expect(rootKeys.isSubset(of: Self.allowedRootKeys))
    }

    @Test func encodedProjectUsesOnlyAllowlistedKeys() throws {
        let project = Project(
            commonDirectoryPath: "/x/.git",
            primaryCheckoutPath: "/x",
            displayName: "x",
            checkoutPaths: ["/x", "/x-wt"]
        )
        let state = PersistedProjectState(projects: [project], lastActiveProjectID: project.id)

        let data = try JSONEncoder().encode(state)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let projectsArray = try #require(object["projects"] as? [[String: Any]])
        let projectKeys = try #require(projectsArray.first.map { Set($0.keys) })

        #expect(projectKeys.isSubset(of: Self.allowedProjectKeys))
    }

    @Test func persistedStateContainsNoSecretShapedKeys() throws {
        // Populate every persisted surface — root payload, a Project with
        // multiple checkout paths, and the `lastActiveProjectID` — so the
        // recursion has something to walk through every nested level.
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme",
            checkoutPaths: ["/Users/dev/acme", "/Users/dev/acme-wt"]
        )
        let state = PersistedProjectState(projects: [project], lastActiveProjectID: project.id)

        let data = try JSONEncoder().encode(state)
        let object = try JSONSerialization.jsonObject(with: data)

        let offending = Self.collectSecretShapedKeys(in: object)
        #expect(offending.isEmpty, "secret-shaped keys leaked into persisted state: \(offending)")
    }

    @Test func savedFileContainsNoSecretShapedKeysOnDisk() throws {
        // Belt-and-suspenders for the in-memory check: round-trip through the
        // actual `ProjectStore` write so a future change to encoder options or
        // a wrapping layer can't quietly slip a secret through.
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme",
            checkoutPaths: ["/Users/dev/acme", "/Users/dev/acme-wt"]
        )
        try ProjectStore(fileURL: url).save(
            PersistedProjectState(projects: [project], lastActiveProjectID: project.id)
        )

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)

        let offending = Self.collectSecretShapedKeys(in: object)
        #expect(offending.isEmpty, "secret-shaped keys leaked into projects.json: \(offending)")
    }

    /// Recursively collect any JSON keys that match one of the secret-shape
    /// substrings. Walks both dictionaries and arrays so a future nested
    /// payload (e.g. a GitHub metadata object embedded inside Project) is
    /// also guarded without anyone having to remember to update the test.
    private static func collectSecretShapedKeys(in node: Any) -> [String] {
        var hits: [String] = []
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                let lowered = key.lowercased()
                if secretLikeKeySubstrings.contains(where: { lowered.contains($0) }) {
                    hits.append(key)
                }
                hits.append(contentsOf: collectSecretShapedKeys(in: value))
            }
        } else if let array = node as? [Any] {
            for element in array {
                hits.append(contentsOf: collectSecretShapedKeys(in: element))
            }
        }
        return hits
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
