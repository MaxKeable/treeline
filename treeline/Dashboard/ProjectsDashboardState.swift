import Foundation

/// Observable state for the Projects dashboard.
///
/// Holds the loaded Projects, resolves newly added paths through `GitClient`,
/// de-duplicates by canonical git common directory, attaches sibling
/// checkouts and worktrees to existing Projects, persists changes through
/// `ProjectStore`, and tracks which Project is currently active so the next
/// launch can reopen it. Branch state, sync state, capability flags, and
/// refresh orchestration belong in later slices.
@MainActor
@Observable
final class ProjectsDashboardState {
    private(set) var projects: [Project]
    private(set) var activeProjectID: String?
    var lastAddError: String?
    /// Transient message shown when a selected path was attached to an
    /// existing Project rather than creating a new one. The view surfaces
    /// this as a non-blocking banner and clears it after a short delay.
    var attachedNotice: String?

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

    /// Resolve the selected path to a git identity, discover sibling
    /// worktrees, then either add a new Project or attach the selected path
    /// (and any newly discovered worktrees) to the existing Project that
    /// shares the same git common directory. The original primary checkout
    /// is preserved on attach.
    @discardableResult
    func addProject(at selectedPath: URL) async throws -> AddOutcome {
        guard let gitClient else {
            throw AddProjectError.notConfigured
        }
        let identity = try await gitClient.resolveIdentity(at: selectedPath)
        // Worktree discovery is best-effort: a missing git binary or a repo
        // version older than `git worktree list --porcelain` must not block
        // adding the Project. Failure just means we only record what the
        // user explicitly selected.
        let discovered = (try? await gitClient.listWorktreePaths(at: identity.checkoutRoot)) ?? []

        if let existingIndex = projects.firstIndex(where: {
            $0.commonDirectoryPath == identity.commonDirectory.path
        }) {
            var existing = projects[existingIndex]
            var merged = Set(existing.checkoutPaths)
            merged.insert(identity.checkoutRoot.path)
            for url in discovered { merged.insert(url.path) }
            existing.checkoutPaths = merged.sorted()
            projects[existingIndex] = existing
            try persist()
            attachedNotice = "Attached to existing Project “\(existing.displayName)”"
            return .attachedToExisting(existing)
        }

        let project = Project(identity: identity, discoveredCheckouts: discovered)
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
