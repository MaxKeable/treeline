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
