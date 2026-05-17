import Foundation

/// Marker protocol for types that are allowed to flow into Treeline's on-disk
/// JSON state in Application Support. The marker is a documentation contract,
/// not a runtime check: anything tagged `NonSecretPersistable` is explicitly
/// promising that none of its (current or future) Codable fields hold an API
/// key, OAuth token, `gh` credential, AI provider secret, or other material
/// that would compromise the user if the JSON file were read, synced, or
/// shared during dogfooding.
///
/// **Secrets do not go here.** When a future slice adds AI provider keys or
/// any other credential, store them in Keychain (under a Treeline service
/// name) and persist only the non-secret reference — e.g. the provider id,
/// the account label, the Keychain item identifier — through this state.
/// Anything else is a regression of this boundary.
///
/// See the doc comment on `PersistedProjectState` for the full rationale.
protocol NonSecretPersistable: Codable {}

/// Versioned JSON payload written to Application Support. Versioning lets
/// later slices migrate as the Project model grows (worktrees, GitHub
/// metadata, etc.). `lastActiveProjectID` is optional so older payloads
/// decode cleanly and so downgrades that drop the field still round-trip.
///
/// # Storage boundary
///
/// This payload is the **only** Treeline state written to disk as plain JSON
/// today, and it is explicitly non-secret. The file lives in
/// `Application Support/Treeline/projects.json`, gets pretty-printed for
/// dogfooding visibility, and may be diffed, backed up, or copied between
/// machines by the user.
///
/// The allowlist for fields on this type (and on any nested
/// `NonSecretPersistable`) is:
///
/// - Project identity and display data (common dir, checkout paths, name)
/// - GitHub repository metadata that is already public on github.com
///   (owner/name only — never tokens)
/// - Dashboard preferences (e.g. last active Project)
///
/// Secrets — API keys, OAuth/PAT tokens, `gh` credentials, future AI
/// provider keys, anything else that would harm the user if leaked — must
/// live in Keychain instead. Future settings work that introduces such
/// material is responsible for adding a Keychain wrapper; it must not extend
/// this state with the secret itself. Persist only non-secret references
/// (provider id, account label, Keychain item identifier) here.
///
/// `ProjectStoreTests` enforces this with a key-allowlist guard and a
/// secret-name recursion check; adding a field that looks like a credential
/// will fail those tests by design.
struct PersistedProjectState: NonSecretPersistable, Equatable {
    static let currentSchemaVersion = 2

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
///
/// `save` accepts only `PersistedProjectState`, which is tagged
/// `NonSecretPersistable`. This is the documented chokepoint for everything
/// that hits disk in plain JSON; secrets belong in Keychain, not here. See
/// `NonSecretPersistable` and `PersistedProjectState` for the full contract.
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
