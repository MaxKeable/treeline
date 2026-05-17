import Foundation
import Testing
@testable import treeline

@MainActor
struct ProjectsDashboardStateTests {

    @Test func newStateIsEmpty() {
        let state = ProjectsDashboardState()
        #expect(state.isEmpty)
        #expect(state.projects.isEmpty)
    }

    @Test func stateWithProjectsIsNotEmpty() {
        let project = Project(
            commonDirectoryPath: "/tmp/treeline/.git",
            primaryCheckoutPath: "/tmp/treeline",
            displayName: "treeline"
        )
        let state = ProjectsDashboardState(projects: [project])
        #expect(!state.isEmpty)
        #expect(state.projects.count == 1)
    }

    @Test func projectsAreEquatableByContents() {
        let a = Project(
            commonDirectoryPath: "/tmp/treeline/.git",
            primaryCheckoutPath: "/tmp/treeline",
            displayName: "treeline"
        )
        let b = Project(
            commonDirectoryPath: "/tmp/treeline/.git",
            primaryCheckoutPath: "/tmp/treeline",
            displayName: "treeline"
        )
        #expect(a == b)
        #expect(a.id == "/tmp/treeline/.git")
    }

    @Test func addProjectResolvesIdentityPersistsAndStoresPrimaryCheckout() async throws {
        let fm = FileManager.default
        let storeURL = fm.temporaryDirectory
            .appendingPathComponent("treeline-add-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        defer { try? fm.removeItem(at: storeURL.deletingLastPathComponent()) }

        let runner = FakeCLIRunner()
        let selected = URL(fileURLWithPath: "/Users/dev/acme/src/feature")
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "/Users/dev/acme\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "/Users/dev/acme/.git\n")

        let state = ProjectsDashboardState(
            store: ProjectStore(fileURL: storeURL),
            gitClient: GitClient(runner: runner)
        )

        let outcome = try await state.addProject(at: selected)

        guard case .added(let added) = outcome else {
            Issue.record("expected .added outcome, got \(outcome)")
            return
        }
        #expect(added.commonDirectoryPath == "/Users/dev/acme/.git")
        #expect(added.primaryCheckoutPath == "/Users/dev/acme")
        #expect(added.displayName == "acme")

        // Persisted to JSON for the next launch.
        let reloaded = ProjectStore(fileURL: storeURL).load()
        #expect(reloaded.projects == [added])
        // Adding alone does not change the active Project — that happens
        // through navigation.
        #expect(reloaded.lastActiveProjectID == nil)
    }

    @Test func coldStartWithNoProjectsHasNoActiveProject() {
        let fm = FileManager.default
        let storeURL = fm.temporaryDirectory
            .appendingPathComponent("treeline-cold-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        defer { try? fm.removeItem(at: storeURL.deletingLastPathComponent()) }

        let state = ProjectsDashboardState(
            store: ProjectStore(fileURL: storeURL),
            gitClient: GitClient(runner: FakeCLIRunner())
        )

        #expect(state.isEmpty)
        #expect(state.activeProject == nil)
    }

    @Test func launchRestoresLastActiveProjectWhenItStillExists() throws {
        let fm = FileManager.default
        let storeURL = fm.temporaryDirectory
            .appendingPathComponent("treeline-restore-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        defer { try? fm.removeItem(at: storeURL.deletingLastPathComponent()) }

        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        try ProjectStore(fileURL: storeURL).save(
            PersistedProjectState(projects: [project], lastActiveProjectID: project.id)
        )

        let state = ProjectsDashboardState(
            store: ProjectStore(fileURL: storeURL),
            gitClient: GitClient(runner: FakeCLIRunner())
        )

        #expect(state.activeProject == project)
        #expect(state.activeProjectID == project.id)
    }

    @Test func launchFallsBackToDashboardWhenLastActiveProjectIsMissing() throws {
        let fm = FileManager.default
        let storeURL = fm.temporaryDirectory
            .appendingPathComponent("treeline-missing-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        defer { try? fm.removeItem(at: storeURL.deletingLastPathComponent()) }

        let surviving = Project(
            commonDirectoryPath: "/Users/dev/widgets/.git",
            primaryCheckoutPath: "/Users/dev/widgets",
            displayName: "widgets"
        )
        try ProjectStore(fileURL: storeURL).save(
            PersistedProjectState(
                projects: [surviving],
                lastActiveProjectID: "/Users/dev/gone/.git"
            )
        )

        let state = ProjectsDashboardState(
            store: ProjectStore(fileURL: storeURL),
            gitClient: GitClient(runner: FakeCLIRunner())
        )

        #expect(state.projects == [surviving])
        #expect(state.activeProject == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test func setActiveProjectPersistsAcrossLaunches() throws {
        let fm = FileManager.default
        let storeURL = fm.temporaryDirectory
            .appendingPathComponent("treeline-set-active-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        defer { try? fm.removeItem(at: storeURL.deletingLastPathComponent()) }

        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        try ProjectStore(fileURL: storeURL).save(
            PersistedProjectState(projects: [project])
        )

        let state = ProjectsDashboardState(
            store: ProjectStore(fileURL: storeURL),
            gitClient: GitClient(runner: FakeCLIRunner())
        )
        #expect(state.activeProject == nil)

        state.setActiveProject(project)
        #expect(state.activeProject == project)

        let reloaded = ProjectStore(fileURL: storeURL).load()
        #expect(reloaded.lastActiveProjectID == project.id)

        // Clearing the active Project also persists.
        state.setActiveProject(nil)
        let reloadedAfterClear = ProjectStore(fileURL: storeURL).load()
        #expect(reloadedAfterClear.lastActiveProjectID == nil)
    }

    @Test func setActiveProjectIgnoresUnknownProject() {
        let known = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        let stranger = Project(
            commonDirectoryPath: "/Users/dev/other/.git",
            primaryCheckoutPath: "/Users/dev/other",
            displayName: "other"
        )
        let state = ProjectsDashboardState(projects: [known])
        state.setActiveProject(stranger)
        #expect(state.activeProject == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test func addProjectAttachesWhenCommonDirectoryAlreadyKnown() async throws {
        let existing = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )

        let runner = FakeCLIRunner()
        // A different selected path inside the same repo (or one of its
        // worktrees) resolves to the same common directory.
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "/Users/dev/acme-wt\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "/Users/dev/acme/.git\n")
        runner.stub(
            arguments: ["worktree", "list", "--porcelain"],
            stdout: """
            worktree /Users/dev/acme
            HEAD abc
            branch refs/heads/main

            worktree /Users/dev/acme-wt
            HEAD def
            branch refs/heads/feature
            """
        )

        let state = ProjectsDashboardState(
            projects: [existing],
            gitClient: GitClient(runner: runner)
        )

        let outcome = try await state.addProject(at: URL(fileURLWithPath: "/Users/dev/acme-wt"))

        guard case .attachedToExisting(let attached) = outcome else {
            Issue.record("expected .attachedToExisting outcome, got \(outcome)")
            return
        }
        #expect(state.projects.count == 1)
        // Identity (and so the dashboard row) is unchanged.
        #expect(attached.id == existing.id)
        #expect(attached.primaryCheckoutPath == existing.primaryCheckoutPath)
        #expect(attached.displayName == existing.displayName)
        // The attached worktree is now tracked alongside the original primary.
        #expect(attached.checkoutPaths == ["/Users/dev/acme", "/Users/dev/acme-wt"])
        // A non-blocking confirmation is set so the view can surface it.
        #expect(state.attachedNotice != nil)
    }

    @Test func addProjectAttachesFromNestedPathInsideWorktree() async throws {
        let existing = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )

        let runner = FakeCLIRunner()
        // User picked a folder buried inside a worktree (e.g. `src/feature`).
        // git resolves it to the worktree root, which shares the common dir.
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "/Users/dev/acme-wt\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "/Users/dev/acme/.git\n")
        runner.stub(
            arguments: ["worktree", "list", "--porcelain"],
            stdout: """
            worktree /Users/dev/acme
            HEAD abc
            branch refs/heads/main

            worktree /Users/dev/acme-wt
            HEAD def
            branch refs/heads/feature
            """
        )

        let state = ProjectsDashboardState(
            projects: [existing],
            gitClient: GitClient(runner: runner)
        )

        let outcome = try await state.addProject(
            at: URL(fileURLWithPath: "/Users/dev/acme-wt/src/feature")
        )

        guard case .attachedToExisting(let attached) = outcome else {
            Issue.record("expected .attachedToExisting outcome, got \(outcome)")
            return
        }
        #expect(state.projects.count == 1)
        #expect(attached.primaryCheckoutPath == "/Users/dev/acme")
        #expect(attached.checkoutPaths.contains("/Users/dev/acme-wt"))
    }

    @Test func addProjectPreservesPrimaryCheckoutWhenAttaching() async throws {
        let existing = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "/Users/dev/acme-wt\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "/Users/dev/acme/.git\n")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let state = ProjectsDashboardState(
            projects: [existing],
            gitClient: GitClient(runner: runner)
        )

        _ = try await state.addProject(at: URL(fileURLWithPath: "/Users/dev/acme-wt"))

        // Even though the user is now adding a different checkout, the
        // originally-added one stays primary so the dashboard label and
        // restored-on-launch path don't shift under them.
        #expect(state.projects[0].primaryCheckoutPath == "/Users/dev/acme")
        #expect(state.projects[0].displayName == "acme")
    }

    @Test func addProjectRecordsDiscoveredWorktreesOnFirstAdd() async throws {
        let fm = FileManager.default
        let storeURL = fm.temporaryDirectory
            .appendingPathComponent("treeline-discover-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        defer { try? fm.removeItem(at: storeURL.deletingLastPathComponent()) }

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "/Users/dev/acme\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "/Users/dev/acme/.git\n")
        runner.stub(
            arguments: ["worktree", "list", "--porcelain"],
            stdout: """
            worktree /Users/dev/acme
            HEAD abc
            branch refs/heads/main

            worktree /Users/dev/acme-wt
            HEAD def
            branch refs/heads/feature
            """
        )

        let state = ProjectsDashboardState(
            store: ProjectStore(fileURL: storeURL),
            gitClient: GitClient(runner: runner)
        )

        let outcome = try await state.addProject(at: URL(fileURLWithPath: "/Users/dev/acme"))
        guard case .added(let added) = outcome else {
            Issue.record("expected .added outcome, got \(outcome)")
            return
        }
        #expect(added.checkoutPaths == ["/Users/dev/acme", "/Users/dev/acme-wt"])

        let reloaded = ProjectStore(fileURL: storeURL).load()
        #expect(reloaded.projects.first?.checkoutPaths == ["/Users/dev/acme", "/Users/dev/acme-wt"])
    }

    @Test func addProjectSucceedsWhenWorktreeDiscoveryFails() async throws {
        // Older git versions or non-standard repos may fail `git worktree
        // list --porcelain`. Adding the Project should still succeed; we
        // just record the primary checkout alone.
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "/Users/dev/acme\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "/Users/dev/acme/.git\n")
        runner.stubFailure(
            arguments: ["worktree", "list", "--porcelain"],
            error: .nonZeroExit(status: 1, standardError: "boom", standardOutput: "")
        )

        let state = ProjectsDashboardState(gitClient: GitClient(runner: runner))
        let outcome = try await state.addProject(at: URL(fileURLWithPath: "/Users/dev/acme"))

        guard case .added(let added) = outcome else {
            Issue.record("expected .added outcome, got \(outcome)")
            return
        }
        #expect(added.checkoutPaths == ["/Users/dev/acme"])
    }

    @Test func healthDefaultsToLoadingBeforeAnyRefresh() {
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        let state = ProjectsDashboardState(projects: [project])
        // No refresher and no entry yet — the dashboard sees the loading
        // sentinel so it can render the row without special-casing missing
        // health.
        #expect(state.health(for: project) == .loading)
    }

    @Test func refreshHealthUpdatesOneProjectWithoutTouchingOthers() async throws {
        let fm = FileManager.default
        let checkoutA = fm.temporaryDirectory.appendingPathComponent("treeline-health-a-\(UUID().uuidString)")
        let checkoutB = fm.temporaryDirectory.appendingPathComponent("treeline-health-b-\(UUID().uuidString)")
        try fm.createDirectory(at: checkoutA, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkoutB, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: checkoutA)
            try? fm.removeItem(at: checkoutB)
        }

        let projectA = Project(
            commonDirectoryPath: checkoutA.path + "/.git",
            primaryCheckoutPath: checkoutA.path,
            displayName: "acme"
        )
        let projectB = Project(
            commonDirectoryPath: checkoutB.path + "/.git",
            primaryCheckoutPath: checkoutB.path,
            displayName: "widgets"
        )

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let state = ProjectsDashboardState(
            projects: [projectA, projectB],
            gitClient: GitClient(runner: runner),
            healthRefresher: ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        )

        await state.refreshHealth(for: projectA)

        // A flips to ready; B stays untouched (still .loading default).
        #expect(state.health(for: projectA).status == .ready)
        #expect(state.health(for: projectB) == .loading)
    }

    @Test func refreshAllHealthHandlesMixOfReadyAndDegradedProjects() async throws {
        let fm = FileManager.default
        let liveCheckout = fm.temporaryDirectory.appendingPathComponent("treeline-live-\(UUID().uuidString)")
        try fm.createDirectory(at: liveCheckout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: liveCheckout) }

        let live = Project(
            commonDirectoryPath: liveCheckout.path + "/.git",
            primaryCheckoutPath: liveCheckout.path,
            displayName: "live"
        )
        let gone = Project(
            commonDirectoryPath: "/Users/dev/missing/.git",
            primaryCheckoutPath: "/Users/dev/definitely-missing-\(UUID().uuidString)",
            displayName: "gone"
        )

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: " M foo\n")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let state = ProjectsDashboardState(
            projects: [live, gone],
            gitClient: GitClient(runner: runner),
            healthRefresher: ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        )

        await state.refreshAllHealth()

        #expect(state.health(for: live).status == .ready)
        #expect(state.health(for: live).workingTree == .dirty)
        if case .degraded = state.health(for: gone).status {
            // expected
        } else {
            Issue.record("expected gone Project to be degraded")
        }
    }

    @Test func refreshHealthIgnoresProjectRemovedMidFlight() async throws {
        // Refresh result for a Project the user has just deleted must not be
        // written back — otherwise the dashboard would resurrect stale state
        // keyed under an absent Project.
        let fm = FileManager.default
        let checkout = fm.temporaryDirectory.appendingPathComponent("treeline-removed-\(UUID().uuidString)")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkout) }

        let project = Project(
            commonDirectoryPath: checkout.path + "/.git",
            primaryCheckoutPath: checkout.path,
            displayName: "acme"
        )

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        // Construct the state *without* the project so the post-refresh
        // membership check filters the result out, simulating "removed
        // mid-flight". This avoids needing a hook in the refresher.
        let state = ProjectsDashboardState(
            projects: [],
            gitClient: GitClient(runner: runner),
            healthRefresher: ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        )

        await state.refreshHealth(for: project)

        #expect(state.healthByProjectID[project.id] == nil)
    }

    @Test func isRefreshingReportsTrueWhileProbeIsInFlight() async throws {
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        let probe = ManualHealthProbe()
        let state = ProjectsDashboardState(
            projects: [project],
            healthRefresher: probe
        )

        #expect(!state.isRefreshing(project))

        let refreshTask = Task { await state.refreshHealth(for: project) }
        // The state synchronously marks itself refreshing before awaiting,
        // so a single yield is enough to surface the in-flight flag in tests.
        while !state.isRefreshing(project) { await Task.yield() }

        #expect(state.isRefreshing(project))
        // Previous data isn't available yet, so the loading sentinel is what
        // the dashboard sees while the probe runs.
        #expect(state.health(for: project) == .loading)

        let resolved = ProjectHealth(
            status: .ready,
            currentBranch: "main",
            workingTree: .clean,
            branchSync: nil,
            worktreeCount: 1,
            lastRefreshedAt: Date()
        )
        probe.complete(project.id, with: resolved)
        await refreshTask.value

        #expect(!state.isRefreshing(project))
        #expect(state.health(for: project) == resolved)
    }

    @Test func cancelAllRefreshesDropsInFlightResultAndClearsFlag() async throws {
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        let probe = ManualHealthProbe()
        let state = ProjectsDashboardState(
            projects: [project],
            healthRefresher: probe
        )

        let refreshTask = Task { await state.refreshHealth(for: project) }
        while !state.isRefreshing(project) { await Task.yield() }

        state.cancelAllRefreshes()
        await refreshTask.value

        // Cancellation drops the in-flight result so a screen switch or app
        // deactivation can't clobber state with work the user no longer
        // cares about. The loading sentinel set when refresh started remains.
        #expect(state.health(for: project) == .loading)
        #expect(!state.isRefreshing(project))
    }

    @Test func cancelAllRefreshesPreservesPriorSnapshotForRePresentation() async throws {
        // When the user re-opens the dashboard after a cancelled refresh,
        // the previous good data should still be visible — only the
        // in-flight work was dropped.
        let project = Project(
            commonDirectoryPath: "/Users/dev/acme/.git",
            primaryCheckoutPath: "/Users/dev/acme",
            displayName: "acme"
        )
        let probe = ManualHealthProbe()
        let state = ProjectsDashboardState(
            projects: [project],
            healthRefresher: probe
        )

        // First refresh seeds a snapshot.
        let initialTask = Task { await state.refreshHealth(for: project) }
        while !state.isRefreshing(project) { await Task.yield() }
        let initial = ProjectHealth(
            status: .ready,
            currentBranch: "main",
            workingTree: .clean,
            branchSync: nil,
            worktreeCount: 1,
            lastRefreshedAt: Date()
        )
        probe.complete(project.id, with: initial)
        await initialTask.value
        #expect(state.health(for: project) == initial)

        // Second refresh is cancelled mid-flight — the original snapshot
        // must survive the cancellation rather than reverting to loading.
        let cancelledTask = Task { await state.refreshHealth(for: project) }
        while !state.isRefreshing(project) { await Task.yield() }
        state.cancelAllRefreshes()
        await cancelledTask.value

        #expect(state.health(for: project) == initial)
        #expect(!state.isRefreshing(project))
    }

    @Test func isStaleReportsTrueAfterStalenessThresholdElapses() async throws {
        let fm = FileManager.default
        let checkout = fm.temporaryDirectory.appendingPathComponent("treeline-stale-\(UUID().uuidString)")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkout) }

        let project = Project(
            commonDirectoryPath: checkout.path + "/.git",
            primaryCheckoutPath: checkout.path,
            displayName: "acme"
        )

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let refresher = ProjectHealthRefresher(
            gitClient: GitClient(runner: runner),
            now: { clock.now }
        )
        let state = ProjectsDashboardState(
            projects: [project],
            healthRefresher: refresher,
            clock: { clock.now },
            stalenessThreshold: 60
        )

        // No refresh yet → no prior data → not stale.
        #expect(!state.isStale(for: project))

        await state.refreshHealth(for: project)
        #expect(state.health(for: project).status == .ready)
        #expect(!state.isStale(for: project))

        // Wall clock advances past the threshold. The data didn't change,
        // but the dashboard now considers it stale and surfaces that.
        clock.advance(by: 120)
        #expect(state.isStale(for: project))
    }

    @Test func isStaleAppliesToDegradedSnapshotsToo() async throws {
        // Failure rows can also go stale — the user should know that the
        // "Couldn't reach git" message hasn't been re-checked in a while.
        let project = Project(
            commonDirectoryPath: "/Users/dev/gone/.git",
            primaryCheckoutPath: "/Users/dev/definitely-missing-\(UUID().uuidString)",
            displayName: "gone"
        )
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let refresher = ProjectHealthRefresher(
            gitClient: GitClient(runner: FakeCLIRunner()),
            now: { clock.now }
        )
        let state = ProjectsDashboardState(
            projects: [project],
            healthRefresher: refresher,
            clock: { clock.now },
            stalenessThreshold: 60
        )

        await state.refreshHealth(for: project)
        if case .degraded = state.health(for: project).status {
            // expected
        } else {
            Issue.record("expected degraded status, got \(state.health(for: project).status)")
        }
        #expect(!state.isStale(for: project))

        clock.advance(by: 120)
        #expect(state.isStale(for: project))
    }

    @Test func manualRefreshReplacesStaleSnapshotWithFreshOne() async throws {
        // Pressing the refresh button on a stale row should run a new probe
        // and clear the stale flag, regardless of how old the prior data was.
        let fm = FileManager.default
        let checkout = fm.temporaryDirectory.appendingPathComponent("treeline-manual-\(UUID().uuidString)")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkout) }

        let project = Project(
            commonDirectoryPath: checkout.path + "/.git",
            primaryCheckoutPath: checkout.path,
            displayName: "acme"
        )

        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let refresher = ProjectHealthRefresher(
            gitClient: GitClient(runner: runner),
            now: { clock.now }
        )
        let state = ProjectsDashboardState(
            projects: [project],
            healthRefresher: refresher,
            clock: { clock.now },
            stalenessThreshold: 60
        )

        await state.refreshHealth(for: project)
        let firstRefreshAt = state.health(for: project).lastRefreshedAt
        #expect(firstRefreshAt != nil)

        clock.advance(by: 600)
        #expect(state.isStale(for: project))

        await state.refreshHealth(for: project)
        let secondRefreshAt = state.health(for: project).lastRefreshedAt
        #expect(secondRefreshAt != nil)
        #expect(secondRefreshAt! > firstRefreshAt!)
        #expect(!state.isStale(for: project))
    }

    @Test func refreshAllHealthTriggersOneRefreshPerProject() async throws {
        // Simulates the launch / focus-regain trigger: refreshing all health
        // should drive each Project through the probe exactly once and leave
        // none stuck in refreshing afterwards.
        let projects = (0..<3).map { i in
            Project(
                commonDirectoryPath: "/Users/dev/p\(i)/.git",
                primaryCheckoutPath: "/Users/dev/p\(i)",
                displayName: "p\(i)"
            )
        }
        let probe = ManualHealthProbe()
        let state = ProjectsDashboardState(
            projects: projects,
            healthRefresher: probe
        )

        let refreshTask = Task { await state.refreshAllHealth() }
        while probe.pendingCount < projects.count { await Task.yield() }
        #expect(state.refreshingProjectIDs.count == projects.count)

        for project in projects {
            probe.complete(project.id, with: ProjectHealth(
                status: .ready,
                currentBranch: "main",
                workingTree: .clean,
                branchSync: nil,
                worktreeCount: 1,
                lastRefreshedAt: Date()
            ))
        }
        await refreshTask.value

        #expect(state.refreshingProjectIDs.isEmpty)
        for project in projects {
            #expect(state.health(for: project).status == .ready)
        }
    }

    @Test func addProjectSurfacesGitErrors() async throws {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["rev-parse", "--show-toplevel"],
            error: .nonZeroExit(
                status: 128,
                standardError: "fatal: not a git repository\n",
                standardOutput: ""
            )
        )
        let state = ProjectsDashboardState(gitClient: GitClient(runner: runner))

        do {
            _ = try await state.addProject(at: URL(fileURLWithPath: "/tmp"))
            Issue.record("expected error from addProject")
        } catch is GitClientError {
            // expected
        }
        #expect(state.projects.isEmpty)
    }
}

/// HealthProbing fake whose refresh calls suspend until the test resumes
/// them explicitly. Used to verify the dashboard's in-flight indicator and
/// cancellation behaviour without relying on real timing.
final class ManualHealthProbe: HealthProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<ProjectHealth, Never>] = [:]

    func refresh(_ project: Project) async -> ProjectHealth {
        let projectID = project.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProjectHealth, Never>) in
                lock.lock()
                // Re-check cancellation under the lock to close the race
                // where Task.cancel() runs between entering the operation
                // and registering the continuation.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: .loading)
                    return
                }
                pending[projectID] = continuation
                lock.unlock()
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cont = self.pending.removeValue(forKey: projectID)
            self.lock.unlock()
            cont?.resume(returning: .loading)
        }
    }

    func complete(_ projectID: String, with health: ProjectHealth) {
        lock.lock()
        let cont = pending.removeValue(forKey: projectID)
        lock.unlock()
        cont?.resume(returning: health)
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}

/// A clock whose value can be advanced from the test body, used to verify
/// staleness without sleeping the test process.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ initial: Date) { self.current = initial }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
