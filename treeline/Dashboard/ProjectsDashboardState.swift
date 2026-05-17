import Foundation

/// Abstracts the health-probing surface used by the dashboard so tests can
/// inject a controllable fake (e.g. to verify cancellation behaviour). The
/// concrete `ProjectHealthRefresher` conforms in production.
protocol HealthProbing: Sendable {
    func refresh(_ project: Project) async -> ProjectHealth
}

/// Observable state for the Projects dashboard.
///
/// Holds the loaded Projects, resolves newly added paths through `GitClient`,
/// de-duplicates by canonical git common directory, attaches sibling
/// checkouts and worktrees to existing Projects, persists changes through
/// `ProjectStore`, and tracks which Project is currently active so the next
/// launch can reopen it. Refreshes are tracked per Project so the UI can
/// show in-flight, stale, success, and failure states, and so a screen
/// switch or app deactivation can cancel work that the user no longer
/// needs.
@MainActor
@Observable
final class ProjectsDashboardState {
    /// How long a refreshed snapshot is considered "fresh" before the
    /// dashboard renders it as stale. Picked well under any future polling
    /// interval so the user can spot dashboards that haven't been refreshed
    /// since they last opened the app or stepped away.
    static let defaultStalenessThreshold: TimeInterval = 120

    private(set) var projects: [Project]
    private(set) var activeProjectID: String?
    /// Health per Project ID, populated lazily by `refreshHealth`. Projects
    /// with no entry are treated as `.loading` by `health(for:)` so the
    /// dashboard can render before the first refresh completes.
    private(set) var healthByProjectID: [String: ProjectHealth] = [:]
    /// Project IDs with a currently in-flight refresh. Drives the dashboard's
    /// "refreshing" indicator independently of the stored health snapshot, so
    /// the previous snapshot stays visible while the new probe runs.
    private(set) var refreshingProjectIDs: Set<String> = []
    var lastAddError: String?
    /// Transient message shown when a selected path was attached to an
    /// existing Project rather than creating a new one. The view surfaces
    /// this as a non-blocking banner and clears it after a short delay.
    var attachedNotice: String?

    private let store: ProjectStore?
    private let gitClient: GitClient?
    private let healthProbe: (any HealthProbing)?
    private let clock: @Sendable () -> Date
    let stalenessThreshold: TimeInterval

    /// Tracks the in-flight refresh task per Project so `cancelAllRefreshes`
    /// and replacement calls can both cooperatively stop work in progress.
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Per-Project sequence number, bumped on every refresh launch. The post-
    /// await cleanup only clears tracking state if its token still matches —
    /// otherwise a newer refresh has already taken over and owns the entry.
    private var refreshSeq: [String: Int] = [:]
    private var nextRefreshSeq: Int = 0

    init(
        projects: [Project] = [],
        activeProjectID: String? = nil,
        store: ProjectStore? = nil,
        gitClient: GitClient? = nil,
        healthRefresher: (any HealthProbing)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        stalenessThreshold: TimeInterval = ProjectsDashboardState.defaultStalenessThreshold
    ) {
        self.projects = projects
        self.store = store
        self.gitClient = gitClient
        self.healthProbe = healthRefresher
        self.clock = clock
        self.stalenessThreshold = stalenessThreshold
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

    /// Whether a refresh is currently in flight for this Project. The
    /// dashboard uses this to show a refresh indicator without discarding
    /// the previous snapshot.
    func isRefreshing(_ project: Project) -> Bool {
        refreshingProjectIDs.contains(project.id)
    }

    /// Whether the stored snapshot is older than the configured staleness
    /// threshold. Loading rows and rows that have never been refreshed are
    /// not stale — there is no prior data to be stale about.
    func isStale(for project: Project) -> Bool {
        let snapshot = health(for: project)
        guard case .loading = snapshot.status else {
            return staleSince(snapshot.lastRefreshedAt)
        }
        // A row still on the loading sentinel hasn't produced a snapshot yet,
        // so don't paint it as stale.
        if snapshot.lastRefreshedAt == nil { return false }
        return staleSince(snapshot.lastRefreshedAt)
    }

    private func staleSince(_ date: Date?) -> Bool {
        guard let date else { return false }
        return clock().timeIntervalSince(date) > stalenessThreshold
    }

    /// Refresh one Project's health without touching any other Project's
    /// state. The previous snapshot stays visible while the new probe runs
    /// so the dashboard never flashes back to "loading…" on a re-refresh.
    /// Cancellable through `cancelAllRefreshes()`.
    func refreshHealth(for project: Project) async {
        guard let healthProbe else { return }
        guard projects.contains(where: { $0.id == project.id }) else { return }

        // Replace any in-flight refresh for this Project — the newer request
        // wins and the older one's result is discarded.
        refreshTasks[project.id]?.cancel()

        if healthByProjectID[project.id] == nil {
            healthByProjectID[project.id] = .loading
        }

        nextRefreshSeq += 1
        let token = nextRefreshSeq
        refreshSeq[project.id] = token
        refreshingProjectIDs.insert(project.id)

        let projectID = project.id
        let task = Task<Void, Never> { @MainActor [weak self] in
            let updated = await healthProbe.refresh(project)
            // Cancellation observed after the probe returns: drop the result
            // so a screen switch or app deactivation can't clobber state
            // with a snapshot the user no longer cares about.
            if Task.isCancelled { return }
            guard let self else { return }
            guard self.projects.contains(where: { $0.id == projectID }) else { return }
            self.healthByProjectID[projectID] = updated
        }
        refreshTasks[projectID] = task
        await task.value

        // Only clear tracking state if no newer refresh has taken over.
        if refreshSeq[projectID] == token {
            refreshSeq.removeValue(forKey: projectID)
            refreshTasks.removeValue(forKey: projectID)
            refreshingProjectIDs.remove(projectID)
        }
    }

    /// Refresh every Project's health. Errors on one Project never affect
    /// the others — each refresh resolves to either ready or degraded health.
    func refreshAllHealth() async {
        let snapshot = projects
        await withTaskGroup(of: Void.self) { group in
            for project in snapshot {
                group.addTask { @MainActor [weak self] in
                    await self?.refreshHealth(for: project)
                }
            }
        }
    }

    /// Cancel every in-flight refresh and clear the in-flight set. The
    /// dashboard calls this when the user navigates away or the app loses
    /// active focus so we don't keep probing git for views the user can't see.
    func cancelAllRefreshes() {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        refreshSeq.removeAll()
        refreshingProjectIDs.removeAll()
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
