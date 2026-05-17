import Foundation

/// Observable state for the Projects dashboard.
///
/// Holds the loaded Projects, resolves newly added paths through `GitClient`,
/// de-duplicates by canonical git common directory, and persists changes
/// through `ProjectStore`. Branch state, sync state, capability flags, and
/// refresh orchestration belong in later slices.
@MainActor
@Observable
final class ProjectsDashboardState {
    private(set) var projects: [Project]
    var lastAddError: String?

    private let store: ProjectStore?
    private let gitClient: GitClient?

    init(
        projects: [Project] = [],
        store: ProjectStore? = nil,
        gitClient: GitClient? = nil
    ) {
        self.projects = projects
        self.store = store
        self.gitClient = gitClient
    }

    /// Convenience initializer that loads any persisted Projects from the
    /// given store at construction.
    convenience init(store: ProjectStore, gitClient: GitClient) {
        self.init(projects: store.load(), store: store, gitClient: gitClient)
    }

    var isEmpty: Bool { projects.isEmpty }

    enum AddOutcome: Equatable {
        case added(Project)
        case attachedToExisting(Project)
    }

    /// Resolve the selected path to a git identity, then either add a new
    /// Project or report that the path already belongs to a known one. The
    /// originally added path becomes the primary checkout for new Projects.
    @discardableResult
    func addProject(at selectedPath: URL) async throws -> AddOutcome {
        guard let gitClient else {
            throw AddProjectError.notConfigured
        }
        let identity = try await gitClient.resolveIdentity(at: selectedPath)
        if let existing = projects.first(where: { $0.commonDirectoryPath == identity.commonDirectory.path }) {
            return .attachedToExisting(existing)
        }
        let project = Project(identity: identity)
        projects.append(project)
        try store?.save(projects)
        return .added(project)
    }

    enum AddProjectError: Error, Equatable {
        case notConfigured
    }
}
