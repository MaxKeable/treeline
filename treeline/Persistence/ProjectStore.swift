import Foundation

/// Versioned JSON payload written to Application Support. Versioning lets
/// later slices migrate as the Project model grows (worktrees, GitHub
/// metadata, etc.). `lastActiveProjectID` is optional so older payloads
/// decode cleanly and so downgrades that drop the field still round-trip.
struct PersistedProjectState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [Project]
    var lastActiveProjectID: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projects: [Project] = [],
        lastActiveProjectID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.lastActiveProjectID = lastActiveProjectID
    }
}

/// JSON-backed persistence for Projects. The store treats missing, empty, or
/// corrupt state files as "no projects yet" so a single bad write or a manual
/// edit during dogfooding never crashes the app on launch. Future-version
/// payloads are also ignored so a newer Treeline build can downgrade safely
/// without nuking the user's data — the old file is left in place.
struct ProjectStore {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let treelineDir = appSupport.appendingPathComponent("Treeline", isDirectory: true)
        try fileManager.createDirectory(at: treelineDir, withIntermediateDirectories: true)
        return treelineDir.appendingPathComponent("projects.json")
    }

    func load() -> PersistedProjectState {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return PersistedProjectState()
        }
        guard let state = try? JSONDecoder().decode(PersistedProjectState.self, from: data) else {
            return PersistedProjectState()
        }
        guard state.schemaVersion <= PersistedProjectState.currentSchemaVersion else {
            return PersistedProjectState()
        }
        return state
    }

    func save(_ state: PersistedProjectState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
