import Foundation
import Testing
@testable import treeline

struct ProjectHealthRefresherTests {

    private func makeTempCheckout(_ label: String = "checkout") throws -> URL {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("treeline-health-\(label)-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeProject(at url: URL, displayName: String = "acme") -> Project {
        Project(
            commonDirectoryPath: url.path + "/.git",
            primaryCheckoutPath: url.path,
            displayName: displayName
        )
    }

    @Test func reportsCleanReadyStateWithBranchAndWorktreeCount() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("clean")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(
            arguments: ["worktree", "list", "--porcelain"],
            stdout: """
            worktree \(checkout.path)
            HEAD abc
            branch refs/heads/main

            worktree \(checkout.path)-wt
            HEAD def
            branch refs/heads/feature
            """
        )

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let refresher = ProjectHealthRefresher(
            gitClient: GitClient(runner: runner),
            now: { fixedNow }
        )

        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        #expect(health.currentBranch == "main")
        #expect(health.workingTree == .clean)
        #expect(health.worktreeCount == 2)
        #expect(health.lastRefreshedAt == fixedNow)
    }

    @Test func reportsDirtyWhenStatusPorcelainNonEmpty() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("dirty")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "feature/x\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: " M src/foo.swift\n?? src/new.swift\n")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "worktree \(checkout.path)\n")

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        #expect(health.currentBranch == "feature/x")
        #expect(health.workingTree == .dirty)
        #expect(health.worktreeCount == 1)
    }

    @Test func reportsDegradedWhenPrimaryCheckoutIsMissing() async {
        let project = Project(
            commonDirectoryPath: "/Users/dev/gone/.git",
            primaryCheckoutPath: "/Users/dev/definitely-not-a-real-path-\(UUID().uuidString)",
            displayName: "gone"
        )

        let runner = FakeCLIRunner()
        // No stubs needed — the refresher should never reach git when the
        // path is missing, so any CLI call would assert here.

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        guard case .degraded(let reason) = health.status else {
            Issue.record("expected degraded status, got \(health.status)")
            return
        }
        #expect(reason.lowercased().contains("missing"))
        #expect(health.lastRefreshedAt != nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test func reportsDegradedWhenGitBinaryFailsToLaunch() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("nogit")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            error: .launchFailed("could not find git")
        )
        // Provide stubs for the parallel calls so the FakeCLIRunner doesn't
        // throw `launchFailed("no stub …")` and shadow the intended error.
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        guard case .degraded(let reason) = health.status else {
            Issue.record("expected degraded status, got \(health.status)")
            return
        }
        #expect(reason.contains("git is unavailable") || reason.contains("could not find git"))
    }

    @Test func reportsDegradedWhenGitCommandFails() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("notrepo")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            error: .nonZeroExit(
                status: 128,
                standardError: "fatal: not a git repository\n",
                standardOutput: ""
            )
        )
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        guard case .degraded(let reason) = health.status else {
            Issue.record("expected degraded status, got \(health.status)")
            return
        }
        #expect(reason.contains("not a git repository"))
        #expect(health.currentBranch == nil)
        #expect(health.workingTree == nil)
    }

    @Test func localOnlyRepoIsReadyWithoutGitHubCalls() async throws {
        // The refresher must never depend on `gh` or any GitHub metadata;
        // local-only Projects are first-class. A clean repo with no remote
        // still resolves to .ready.
        let fm = FileManager.default
        let checkout = try makeTempCheckout("local-only")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout, displayName: "local-only")

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "worktree \(checkout.path)\n")

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        // No `gh` invocation should ever have happened.
        for invocation in runner.invocations {
            #expect(invocation.executableURL.lastPathComponent != "gh")
        }
    }

    @Test func reportsDetachedHeadAsNilBranchStillReady() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("detached")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "HEAD\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "worktree \(checkout.path)\n")

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        #expect(health.currentBranch == nil)
        #expect(health.workingTree == .clean)
    }

    @Test func includesBranchSyncFromPorcelainV2() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("sync-ahead")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")
        runner.stub(
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
            stdout: """
            # branch.oid abc
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -0
            """
        )

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        #expect(health.branchSync == .ahead(2))
    }

    @Test func branchSyncFailureLeavesHealthReadyWithUnknownSync() async throws {
        // Sync probe failure must be best-effort — the row falls back to
        // "unknown" rather than degrading the whole snapshot.
        let fm = FileManager.default
        let checkout = try makeTempCheckout("sync-fail")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")
        runner.stubFailure(
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
            error: .nonZeroExit(status: 128, standardError: "boom", standardOutput: "")
        )

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        #expect(health.branchSync == nil)
    }

    @Test func branchSyncSurfacesNoUpstreamForLocalOnlyRepo() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("local-only-sync")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout, displayName: "local-only")

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: "")
        runner.stub(
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
            stdout: """
            # branch.oid abc
            # branch.head main
            """
        )

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.branchSync == .noUpstream)
    }

    @Test func bestEffortWorktreeCountFallsBackToOneOnFailure() async throws {
        let fm = FileManager.default
        let checkout = try makeTempCheckout("wt-fail")
        defer { try? fm.removeItem(at: checkout) }
        let project = makeProject(at: checkout)

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")
        runner.stubFailure(
            arguments: ["worktree", "list", "--porcelain"],
            error: .nonZeroExit(status: 1, standardError: "boom", standardOutput: "")
        )

        let refresher = ProjectHealthRefresher(gitClient: GitClient(runner: runner))
        let health = await refresher.refresh(project)

        #expect(health.status == .ready)
        // Worktree discovery failure must not degrade the snapshot — branch
        // and status still succeeded — but we display "1" for the primary.
        #expect(health.worktreeCount == 1)
    }
}
