import Foundation
import Testing
@testable import treeline

struct GitClientTests {

    @Test func resolvesIdentityFromCheckoutRoot() async throws {
        let runner = FakeCLIRunner()
        let checkout = "/Users/dev/code/acme"
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "\(checkout)\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "\(checkout)/.git\n")

        let client = GitClient(runner: runner)
        let identity = try await client.resolveIdentity(at: URL(fileURLWithPath: checkout))

        #expect(identity.checkoutRoot.path == checkout)
        #expect(identity.commonDirectory.path == "\(checkout)/.git")

        // Each call carries an explicit executable URL and argument array,
        // never a single shell string.
        for invocation in runner.invocations {
            #expect(invocation.executableURL.path == "/usr/bin/git")
            #expect(invocation.arguments.first == "rev-parse")
        }
    }

    @Test func resolvesIdentityFromNestedSelectedFolder() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("treeline-nested-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("src/app", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "\(root.path)\n")
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: "\(root.path)/.git\n")

        let client = GitClient(runner: runner)
        let identity = try await client.resolveIdentity(at: nested)

        #expect(identity.checkoutRoot.path == GitClient.canonicalize(root.path).path)
        #expect(runner.invocations.first?.workingDirectory == nested)
    }

    @Test func canonicalizesPathsThroughSymlinks() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("treeline-canon-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let canonical = GitClient.canonicalize(link)
        #expect(canonical.path == real.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func surfacesCLIErrorsAsNotInsideRepository() async throws {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["rev-parse", "--show-toplevel"],
            error: .nonZeroExit(
                status: 128,
                standardError: "fatal: not a git repository\n",
                standardOutput: ""
            )
        )

        let client = GitClient(runner: runner)
        do {
            _ = try await client.resolveIdentity(at: URL(fileURLWithPath: "/tmp"))
            Issue.record("expected notInsideRepository error")
        } catch let GitClientError.notInsideRepository(_, underlying) {
            #expect(underlying.contains("not a git repository"))
        }
    }

    @Test func parsesWorktreePorcelainOutput() {
        let porcelain = """
        worktree /Users/dev/acme
        HEAD abc123
        branch refs/heads/main

        worktree /Users/dev/acme-feature
        HEAD def456
        branch refs/heads/feature

        worktree /Users/dev/acme-detached
        HEAD 789aaa
        detached

        """
        let paths = GitClient.parseWorktreePaths(porcelain).map { $0.path }
        #expect(paths == [
            "/Users/dev/acme",
            "/Users/dev/acme-feature",
            "/Users/dev/acme-detached"
        ])
    }

    @Test func parsesWorktreePorcelainWithLockedAndPrunableFlags() {
        let porcelain = """
        worktree /Users/dev/acme
        HEAD abc
        branch refs/heads/main

        worktree /Users/dev/acme-old
        HEAD def
        branch refs/heads/old
        locked stale checkout
        prunable
        """
        let paths = GitClient.parseWorktreePaths(porcelain).map { $0.path }
        #expect(paths == ["/Users/dev/acme", "/Users/dev/acme-old"])
    }

    @Test func parsesWorktreePorcelainSkipsBlankAndUnknownLines() {
        // Empty input and noisy input should both yield no false positives.
        #expect(GitClient.parseWorktreePaths("").isEmpty)
        #expect(GitClient.parseWorktreePaths("\n\n\n").isEmpty)
        #expect(GitClient.parseWorktreePaths("HEAD abc\nbranch refs/heads/main\n").isEmpty)
    }

    @Test func listWorktreePathsReturnsCanonicalizedPaths() async throws {
        let fm = FileManager.default
        let checkout = fm.temporaryDirectory
            .appendingPathComponent("treeline-worktree-list-\(UUID().uuidString)")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkout) }

        let runner = FakeCLIRunner()
        let porcelain = """
        worktree \(checkout.path)
        HEAD abc
        branch refs/heads/main

        worktree \(checkout.path)-wt
        HEAD def
        branch refs/heads/feature
        """
        runner.stub(arguments: ["worktree", "list", "--porcelain"], stdout: porcelain)

        let client = GitClient(runner: runner)
        let paths = try await client.listWorktreePaths(at: checkout)
        let expected = [
            GitClient.canonicalize(checkout).path,
            GitClient.canonicalize(URL(fileURLWithPath: "\(checkout.path)-wt")).path
        ]
        #expect(paths.map { $0.path } == expected)
    }

    @Test func listWorktreePathsSurfacesCLIErrorsAsNotInsideRepository() async throws {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["worktree", "list", "--porcelain"],
            error: .nonZeroExit(
                status: 128,
                standardError: "fatal: not a git repository\n",
                standardOutput: ""
            )
        )
        let client = GitClient(runner: runner)
        do {
            _ = try await client.listWorktreePaths(at: URL(fileURLWithPath: "/tmp"))
            Issue.record("expected notInsideRepository error")
        } catch let GitClientError.notInsideRepository(_, underlying) {
            #expect(underlying.contains("not a git repository"))
        }
    }

    @Test func currentBranchReturnsBranchName() async throws {
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "main\n")

        let client = GitClient(runner: runner)
        let branch = try await client.currentBranch(at: URL(fileURLWithPath: "/Users/dev/acme"))
        #expect(branch == "main")
    }

    @Test func currentBranchReturnsNilOnDetachedHead() async throws {
        // `git rev-parse --abbrev-ref HEAD` prints the literal string "HEAD"
        // when HEAD is detached, which we surface as nil.
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--abbrev-ref", "HEAD"], stdout: "HEAD\n")

        let client = GitClient(runner: runner)
        let branch = try await client.currentBranch(at: URL(fileURLWithPath: "/Users/dev/acme"))
        #expect(branch == nil)
    }

    @Test func isWorkingTreeDirtyTrueWhenPorcelainNonEmpty() async throws {
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["status", "--porcelain"], stdout: " M src/foo.swift\n?? new.swift\n")

        let client = GitClient(runner: runner)
        let dirty = try await client.isWorkingTreeDirty(at: URL(fileURLWithPath: "/Users/dev/acme"))
        #expect(dirty)
    }

    @Test func isWorkingTreeDirtyFalseWhenPorcelainEmpty() async throws {
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["status", "--porcelain"], stdout: "")

        let client = GitClient(runner: runner)
        let dirty = try await client.isWorkingTreeDirty(at: URL(fileURLWithPath: "/Users/dev/acme"))
        #expect(!dirty)
    }

    @Test func isWorkingTreeDirtySurfacesCLIErrorsAsNotInsideRepository() async throws {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["status", "--porcelain"],
            error: .nonZeroExit(
                status: 128,
                standardError: "fatal: not a git repository\n",
                standardOutput: ""
            )
        )

        let client = GitClient(runner: runner)
        do {
            _ = try await client.isWorkingTreeDirty(at: URL(fileURLWithPath: "/tmp"))
            Issue.record("expected notInsideRepository error")
        } catch let GitClientError.notInsideRepository(_, underlying) {
            #expect(underlying.contains("not a git repository"))
        }
    }

    // MARK: - Branch sync

    @Test func parsesBranchSyncUpToDate() {
        let porcelain = """
        # branch.oid abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """
        #expect(GitClient.parseBranchSync(porcelain) == .upToDate)
    }

    @Test func parsesBranchSyncAhead() {
        let porcelain = """
        # branch.oid abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -0
        """
        #expect(GitClient.parseBranchSync(porcelain) == .ahead(3))
    }

    @Test func parsesBranchSyncBehind() {
        let porcelain = """
        # branch.oid abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -2
        """
        #expect(GitClient.parseBranchSync(porcelain) == .behind(2))
    }

    @Test func parsesBranchSyncDiverged() {
        let porcelain = """
        # branch.oid abcdef
        # branch.head feature/x
        # branch.upstream origin/feature/x
        # branch.ab +4 -7
        """
        #expect(GitClient.parseBranchSync(porcelain) == .diverged(ahead: 4, behind: 7))
    }

    @Test func parsesBranchSyncNoUpstream() {
        // Branch exists but has no configured upstream — porcelain v2 omits
        // both `# branch.upstream` and `# branch.ab`.
        let porcelain = """
        # branch.oid abcdef
        # branch.head local-only
        """
        #expect(GitClient.parseBranchSync(porcelain) == .noUpstream)
    }

    @Test func parsesBranchSyncDetachedHead() {
        let porcelain = """
        # branch.oid abcdef
        # branch.head (detached)
        """
        #expect(GitClient.parseBranchSync(porcelain) == .detached)
    }

    @Test func parsesBranchSyncReturnsNilForUnrecognizedOutput() {
        // Empty output and noise (e.g. a CLI failure that returned text on
        // stdout) should resolve to .unknown / nil, not crash or fall through.
        #expect(GitClient.parseBranchSync("") == nil)
        #expect(GitClient.parseBranchSync("not git output\n") == nil)
        // Malformed ab line — counts unparseable.
        let malformed = """
        # branch.head main
        # branch.upstream origin/main
        # branch.ab garbage
        """
        #expect(GitClient.parseBranchSync(malformed) == nil)
    }

    @Test func branchSyncInvokesPorcelainV2Status() async throws {
        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
            stdout: """
            # branch.oid abc
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +1 -0
            """
        )
        let client = GitClient(runner: runner)
        let sync = try await client.branchSync(at: URL(fileURLWithPath: "/Users/dev/acme"))
        #expect(sync == .ahead(1))
        #expect(runner.invocations.first?.executableURL.path == "/usr/bin/git")
    }

    @Test func branchSyncSurfacesCLIErrorsAsNotInsideRepository() async throws {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=no"],
            error: .nonZeroExit(
                status: 128,
                standardError: "fatal: not a git repository\n",
                standardOutput: ""
            )
        )
        let client = GitClient(runner: runner)
        do {
            _ = try await client.branchSync(at: URL(fileURLWithPath: "/tmp"))
            Issue.record("expected notInsideRepository error")
        } catch let GitClientError.notInsideRepository(_, underlying) {
            #expect(underlying.contains("not a git repository"))
        }
    }

    @Test func relativeCommonDirIsResolvedAgainstWorkingDirectory() async throws {
        let fm = FileManager.default
        let checkout = fm.temporaryDirectory.appendingPathComponent("treeline-relcommon-\(UUID().uuidString)")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkout) }

        let runner = FakeCLIRunner()
        runner.stub(arguments: ["rev-parse", "--show-toplevel"], stdout: "\(checkout.path)\n")
        // Real git often prints `.git` when called from inside the worktree.
        runner.stub(arguments: ["rev-parse", "--git-common-dir"], stdout: ".git\n")

        let client = GitClient(runner: runner)
        let identity = try await client.resolveIdentity(at: checkout)

        let expected = GitClient.canonicalize(checkout.appendingPathComponent(".git"))
        #expect(identity.commonDirectory.path == expected.path)
    }
}
