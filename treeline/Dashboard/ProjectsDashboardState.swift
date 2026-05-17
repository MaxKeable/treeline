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
    /// Health per Project ID, populated lazily by `refreshHealth`. Projects
    /// with no entry are treated as `.loading` by `health(for:)` so the
    /// dashboard can render before the first refresh completes.
    private(set) var healthByProjectID: [String: ProjectHealth] = [:]
    var lastAddError: String?
    /// Transient message shown when a selected path was attached to an
    /// existing Project rather than creating a new one. The view surfaces
    /// this as a non-blocking banner and clears it after a short delay.
    var attachedNotice: String?

    private let store: ProjectStore?
    private let gitClient: GitClient?
    private let healthRefresher: ProjectHealthRefresher?

    init(
        projects: [Project] = [],
        activeProjectID: String? = nil,
        store: ProjectStore? = nil,
        gitClient: GitClient? = nil,
        healthRefresher: ProjectHealthRefresher? = nil
    ) {
        self.projects = projects
        self.store = store
        self.gitClient = gitClient
        self.healthRefresher = healthRefresher
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
            gitClient: gitClient,
            healthRefresher: ProjectHealthRefresher(gitClient: gitClient)
        )
    }

    /// Health for a Project. Returns `.loading` if no refresh has completed
    /// yet so the dashboard never has to special-case "missing entry".
    func health(for project: Project) -> ProjectHealth {
        healthByProjectID[project.id] ?? .loading
    }

    /// Refresh one Project's health without touching any other Project's
    /// state. The Project's row flips to `.loading` while the probe runs and
    /// the result is dropped if the Project was removed mid-refresh.
    func refreshHealth(for project: Project) async {
        guard let healthRefresher else { return }
        guard projects.contains(where: { $0.id == project.id }) else { return }
        if healthByProjectID[project.id] == nil {
            healthByProjectID[project.id] = .loading
        }
        let updated = await healthRefresher.refresh(project)
        guard projects.contains(where: { $0.id == project.id }) else { return }
        healthByProjectID[project.id] = updated
    }

    /// Refresh every Project's health. Errors on one Project never affect
    /// the others — each refresh resolves to either ready or degraded health.
    func refreshAllHealth() async {
        let snapshot = projects
        await withTaskGroup(of: (String, ProjectHealth).self) { group in
            guard let healthRefresher else { return }
            for project in snapshot {
                if healthByProjectID[project.id] == nil {
                    healthByProjectID[project.id] = .loading
                }
                group.addTask {
                    (project.id, await healthRefresher.refresh(project))
                }
            }
            for await (id, health) in group {
                if projects.contains(where: { $0.id == id }) {
                    healthByProjectID[id] = health
                }
            }
        }
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
