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
    /// User-facing message produced by the most recent failed Relocate. The
    /// dashboard surfaces it in its own alert so the wording stays specific
    /// to relocation (mismatched repo, invalid folder, etc.).
    var lastRelocateError: String?
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
    convenience init(
        store: ProjectStore,
        gitClient: GitClient,
        gitHubProbe: (any GitHubCapabilityProbing)? = nil
    ) {
        let persisted = store.load()
        self.init(
            projects: persisted.projects,
            activeProjectID: persisted.lastActiveProjectID,
            store: store,
            gitClient: gitClient,
            healthRefresher: ProjectHealthRefresher(
                gitClient: gitClient,
                gitHubProbe: gitHubProbe
            )
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

    enum ChangePrimaryCheckoutError: Error, Equatable {
        case notConfigured
        case projectNotFound
        /// The candidate path isn't one of the checkouts or worktrees this
        /// Project already tracks. Picking arbitrary new paths is what
        /// `addProject` is for; switching primary is restricted to known
        /// candidates so the user can't accidentally fold an unrelated repo
        /// in via this action.
        case unknownCheckout(path: String)
        /// The candidate exists in our records but no longer exists on disk.
        /// Promoting it to primary would put the dashboard straight into
        /// `.missing`, so we refuse and ask the user to pick a real folder.
        case missingFolder(path: String)
        /// Re-resolving the candidate through git produced a different
        /// `commonDirectoryPath` than the Project's. That means the candidate
        /// is no longer part of this repository (worktree was pruned, folder
        /// got replaced with a sibling clone, etc.) — silently switching would
        /// change Project identity, so we surface it instead.
        case repositoryMismatch(message: String)
    }

    /// Promote one of the Project's known checkouts or worktrees to primary.
    /// Project identity (`commonDirectoryPath`) is preserved — the new primary
    /// only changes which path future git and GitHub probes target. Persists
    /// the change so the choice survives relaunch, and drops the cached health
    /// snapshot so the next refresh runs against the new primary.
    @discardableResult
    func changePrimaryCheckout(_ project: Project, to newPrimary: URL) async throws -> Project {
        guard let gitClient else { throw ChangePrimaryCheckoutError.notConfigured }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw ChangePrimaryCheckoutError.projectNotFound
        }

        let canonical = GitClient.canonicalize(newPrimary).path
        let current = projects[index]

        // Selecting the current primary is a no-op rather than an error —
        // tapping the active row in a picker shouldn't punish the user.
        if canonical == current.primaryCheckoutPath { return current }

        // Restrict primary changes to candidates we already track. Adding a
        // new path is a different action with different invariants.
        guard current.checkoutPaths.contains(canonical) else {
            throw ChangePrimaryCheckoutError.unknownCheckout(path: canonical)
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw ChangePrimaryCheckoutError.missingFolder(path: canonical)
        }

        // Re-verify with git that the candidate still belongs to the same
        // repository. A stale candidate (worktree pruned out from under us,
        // folder replaced with an unrelated clone) would otherwise silently
        // change which repo the dashboard is reporting on.
        let identity: GitIdentity
        do {
            identity = try await gitClient.resolveIdentity(at: URL(fileURLWithPath: canonical))
        } catch let GitClientError.notInsideRepository(_, underlying) {
            let trimmed = underlying.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChangePrimaryCheckoutError.repositoryMismatch(
                message: trimmed.isEmpty
                    ? "The selected checkout no longer resolves to a git repository."
                    : trimmed
            )
        } catch GitClientError.emptyOutput {
            throw ChangePrimaryCheckoutError.repositoryMismatch(
                message: "git produced no output for the selected checkout."
            )
        }

        guard identity.commonDirectory.path == current.commonDirectoryPath else {
            throw ChangePrimaryCheckoutError.repositoryMismatch(
                message: "The selected checkout now belongs to a different repository."
            )
        }

        var updated = current
        updated.primaryCheckoutPath = identity.checkoutRoot.path
        projects[index] = updated

        // The cached snapshot was probed against the old primary; drop it so
        // the next refresh reports state from the new primary instead of
        // briefly showing stale-but-fresh-looking data.
        healthByProjectID.removeValue(forKey: updated.id)

        try persist()
        return updated
    }

    enum RelocateProjectError: Error, Equatable {
        case notConfigured
        /// The selected folder isn't inside a git repository at all.
        case invalidPath(reason: String)
        /// The selected folder resolves to a repository identity that is
        /// already tracked under a *different* Project. Merging or replacing
        /// silently would lose state, so the user has to resolve it
        /// explicitly (remove the other Project, or pick a different path).
        case repositoryMismatch(message: String)
    }

    /// Replace the missing primary checkout with the user-selected folder and
    /// re-resolve the Project's git identity from there. Other state — display
    /// name, sibling worktree paths, active-Project membership — is preserved
    /// so a relocate only "moves" the Project, never resets it.
    ///
    /// - When the new path resolves to the same `commonDirectoryPath` we know
    ///   we're pointing at the same repo on disk (e.g. the user fixed a typo
    ///   in the symlink); previously discovered checkouts are kept.
    /// - When the new path resolves to a *different* common directory but no
    ///   other Project already uses it, we treat that as a successful repair —
    ///   the repository physically moved — and drop stale sibling paths so we
    ///   don't keep advertising checkouts that no longer exist.
    /// - When the new path resolves to a common directory another Project
    ///   already tracks, we refuse with `.repositoryMismatch` instead of
    ///   colliding two Projects under the same identity.
    @discardableResult
    func relocateProject(_ project: Project, to newPath: URL) async throws -> Project {
        guard let gitClient else { throw RelocateProjectError.notConfigured }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            return project
        }

        let identity: GitIdentity
        do {
            identity = try await gitClient.resolveIdentity(at: newPath)
        } catch let GitClientError.notInsideRepository(_, underlying) {
            let trimmed = underlying.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RelocateProjectError.invalidPath(
                reason: trimmed.isEmpty
                    ? "Selected folder is not inside a git repository."
                    : trimmed
            )
        } catch GitClientError.emptyOutput {
            throw RelocateProjectError.invalidPath(
                reason: "git produced no output for the selected folder."
            )
        }

        let newCommonDir = identity.commonDirectory.path
        if newCommonDir != project.commonDirectoryPath,
           projects.contains(where: { $0.id == newCommonDir }) {
            throw RelocateProjectError.repositoryMismatch(
                message: "Another Project already tracks the repository at that folder."
            )
        }

        var updated = projects[index]
        let oldID = updated.id
        let discovered = (try? await gitClient.listWorktreePaths(at: identity.checkoutRoot)) ?? []

        // Re-derive checkout paths from the new location instead of merging
        // with the prior list. The previous primary is missing by definition,
        // and any sibling paths recorded against the old location can't be
        // trusted to still exist either — git is the authoritative source.
        var paths = Set<String>()
        paths.insert(identity.checkoutRoot.path)
        for url in discovered { paths.insert(url.path) }

        updated.commonDirectoryPath = newCommonDir
        updated.primaryCheckoutPath = identity.checkoutRoot.path
        updated.checkoutPaths = paths.sorted()
        projects[index] = updated

        // Migrate id-keyed bookkeeping if the canonical common dir changed
        // on disk. We always drop the prior health snapshot so the row re-
        // probes the new path instead of carrying the "missing" sentinel.
        if oldID != updated.id {
            refreshTasks[oldID]?.cancel()
            refreshTasks.removeValue(forKey: oldID)
            refreshSeq.removeValue(forKey: oldID)
            refreshingProjectIDs.remove(oldID)
            healthByProjectID.removeValue(forKey: oldID)
            if activeProjectID == oldID { activeProjectID = updated.id }
        }
        healthByProjectID.removeValue(forKey: updated.id)

        try persist()
        return updated
    }

    /// Drop a Project from in-memory state and persist the removal. Cancels
    /// any in-flight refresh for that Project and clears the active selection
    /// if it pointed at the removed Project so navigation doesn't dangle.
    func removeProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let projectID = project.id
        refreshTasks[projectID]?.cancel()
        refreshTasks.removeValue(forKey: projectID)
        refreshSeq.removeValue(forKey: projectID)
        refreshingProjectIDs.remove(projectID)
        healthByProjectID.removeValue(forKey: projectID)
        if activeProjectID == projectID {
            activeProjectID = nil
        }
        projects.remove(at: index)
        try? persist()
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
