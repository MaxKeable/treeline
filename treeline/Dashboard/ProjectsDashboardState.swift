import Foundation

/// Observable state for the Projects dashboard.
///
/// Holds the loaded Projects, resolves newly added paths through `GitClient`,
/// de-duplicates by canonical git common directory, persists changes through
/// `ProjectStore`, and tracks which Project is currently active so the next
/// launch can reopen it. Branch state, sync state, capability flags, and
/// refresh orchestration belong in later slices.
@MainActor
@Observable
final class ProjectsDashboardState {
    private(set) var projects: [Project]
    private(set) var activeProjectID: String?
    var lastAddError: String?

    private let store: ProjectStore?
    private let gitClient: GitClient?

    init(
        projects: [Project] = [],
        activeProjectID: String? = nil,
        store: ProjectStore? = nil,
        gitClient: GitClient? = nil
    ) {
        self.projects = projects
        self.store = store
        self.gitClient = gitClient
        // Drop a dangling reference so callers never see an "active" project
        // that isn't in the projects list (e.g. the repo was removed between
        // launches).
        if let activeProjectID, projects.contains(where: { $0.id == activeProjectID }) {
            self.activeProjectID = activeProjectID
        } else {
            self.activeProjectID = nil
        }
    }

    /// Convenience initializer that loads any persisted Projects and the last
    /// active Project from the given store at construction.
    convenience init(store: ProjectStore, gitClient: GitClient) {
        let persisted = store.load()
        self.init(
            projects: persisted.projects,
            activeProjectID: persisted.lastActiveProjectID,
            store: store,
            gitClient: gitClient
        )
    }

    var isEmpty: Bool { projects.isEmpty }

    var activeProject: Project? {
        guard let activeProjectID else { return nil }
        return projects.first(where: { $0.id == activeProjectID })
    }

    /// Set or clear the currently active Project and persist the change so
    /// the next launch can restore it. Unknown Projects are ignored.
    func setActiveProject(_ project: Project?) {
        let newID = project?.id
        if let newID, !projects.contains(where: { $0.id == newID }) { return }
        if newID == activeProjectID { return }
        activeProjectID = newID
        try? persist()
    }

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
        try persist()
        return .added(project)
    }

    enum AddProjectError: Error, Equatable {
        case notConfigured
    }

    private func persist() throws {
        try store?.save(
            PersistedProjectState(
                projects: projects,
                lastActiveProjectID: activeProjectID
            )
        )
    }
}
