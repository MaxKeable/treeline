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
