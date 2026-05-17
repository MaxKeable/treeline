import Foundation
import Testing
@testable import treeline

struct GHClientTests {

    private let ghURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")

    @Test func repoIdentityParsesOwnerAndName() async throws {
        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["repo", "view", "--json", "owner,name"],
            stdout: #"{"name":"treeline","owner":{"login":"MaxKeable"}}"#
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let identity = try await client.repoIdentity(at: URL(fileURLWithPath: "/tmp/x"))
        #expect(identity == GitHubIdentity(owner: "MaxKeable", name: "treeline"))
    }

    @Test func repoIdentityClassifiesMissingGH() async {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["repo", "view", "--json", "owner,name"],
            error: .launchFailed("posix_spawn failed: No such file or directory")
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        do {
            _ = try await client.repoIdentity(at: URL(fileURLWithPath: "/tmp/x"))
            Issue.record("expected ghMissing error")
        } catch let error as GHClientError {
            if case .ghMissing = error { } else {
                Issue.record("expected ghMissing, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func repoIdentityClassifiesAuthFailure() async {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["repo", "view", "--json", "owner,name"],
            error: .nonZeroExit(
                status: 1,
                standardError: "To authenticate, please run gh auth login.\n",
                standardOutput: ""
            )
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        do {
            _ = try await client.repoIdentity(at: URL(fileURLWithPath: "/tmp/x"))
            Issue.record("expected notAuthenticated")
        } catch let error as GHClientError {
            if case .notAuthenticated = error { } else {
                Issue.record("expected notAuthenticated, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func repoIdentityClassifiesNonGitHubRepo() async {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["repo", "view", "--json", "owner,name"],
            error: .nonZeroExit(
                status: 1,
                standardError: "could not determine a GitHub repository from the current directory\n",
                standardOutput: ""
            )
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        do {
            _ = try await client.repoIdentity(at: URL(fileURLWithPath: "/tmp/x"))
            Issue.record("expected notAGitHubRepository")
        } catch let error as GHClientError {
            if case .notAGitHubRepository = error { } else {
                Issue.record("expected notAGitHubRepository, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func repoIdentityClassifiesNetworkFailure() async {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["repo", "view", "--json", "owner,name"],
            error: .nonZeroExit(
                status: 1,
                standardError: "Get \"https://api.github.com\": dial tcp: lookup api.github.com: no such host\n",
                standardOutput: ""
            )
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        do {
            _ = try await client.repoIdentity(at: URL(fileURLWithPath: "/tmp/x"))
            Issue.record("expected networkFailure")
        } catch let error as GHClientError {
            if case .networkFailure = error { } else {
                Issue.record("expected networkFailure, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func repoIdentityFlagsMalformedJSON() async {
        let runner = FakeCLIRunner()
        runner.stub(arguments: ["repo", "view", "--json", "owner,name"], stdout: "{}")
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        do {
            _ = try await client.repoIdentity(at: URL(fileURLWithPath: "/tmp/x"))
            Issue.record("expected malformedOutput")
        } catch let error as GHClientError {
            if case .malformedOutput = error { } else {
                Issue.record("expected malformedOutput, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func openPullRequestCountCountsJSONEntries() async throws {
        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["pr", "list", "--state", "open", "--json", "number", "--limit", "200"],
            stdout: #"[{"number":1},{"number":2},{"number":3}]"#
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let count = try await client.openPullRequestCount(at: URL(fileURLWithPath: "/tmp/x"))
        #expect(count == 3)
    }

    @Test func openPullRequestCountReturnsZeroForEmptyArray() async throws {
        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["pr", "list", "--state", "open", "--json", "number", "--limit", "200"],
            stdout: "[]"
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let count = try await client.openPullRequestCount(at: URL(fileURLWithPath: "/tmp/x"))
        #expect(count == 0)
    }

    @Test func probeReturnsCapableWithIdentityAndCount() async {
        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["repo", "view", "--json", "owner,name"],
            stdout: #"{"name":"treeline","owner":{"login":"MaxKeable"}}"#
        )
        runner.stub(
            arguments: ["pr", "list", "--state", "open", "--json", "number", "--limit", "200"],
            stdout: #"[{"number":42},{"number":43}]"#
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let capability = await client.probe(at: URL(fileURLWithPath: "/tmp/x"))
        guard case .capable(let identity, let count) = capability else {
            Issue.record("expected capable, got \(capability)")
            return
        }
        #expect(identity == GitHubIdentity(owner: "MaxKeable", name: "treeline"))
        #expect(count == 2)
    }

    @Test func probeReturnsUnavailableWhenIdentityFails() async {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["repo", "view", "--json", "owner,name"],
            error: .nonZeroExit(
                status: 1,
                standardError: "no github remote configured\n",
                standardOutput: ""
            )
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let capability = await client.probe(at: URL(fileURLWithPath: "/tmp/x"))
        guard case .unavailable(let reason) = capability else {
            Issue.record("expected unavailable, got \(capability)")
            return
        }
        #expect(reason == "No GitHub remote")
    }

    @Test func probeKeepsCapableWhenOnlyPRCountFails() async {
        let runner = FakeCLIRunner()
        runner.stub(
            arguments: ["repo", "view", "--json", "owner,name"],
            stdout: #"{"name":"treeline","owner":{"login":"MaxKeable"}}"#
        )
        runner.stubFailure(
            arguments: ["pr", "list", "--state", "open", "--json", "number", "--limit", "200"],
            error: .nonZeroExit(status: 1, standardError: "boom", standardOutput: "")
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let capability = await client.probe(at: URL(fileURLWithPath: "/tmp/x"))
        guard case .capable(_, let count) = capability else {
            Issue.record("expected capable with nil count, got \(capability)")
            return
        }
        // Identity succeeded so the GitHub badge stays on, but the count is
        // suppressed rather than the whole capability collapsing.
        #expect(count == nil)
    }

    @Test func probeReturnsUnavailableWhenGHMissing() async {
        let runner = FakeCLIRunner()
        runner.stubFailure(
            arguments: ["repo", "view", "--json", "owner,name"],
            error: .launchFailed("no such file")
        )
        let client = GHClient(runner: runner, ghExecutableURL: ghURL)
        let capability = await client.probe(at: URL(fileURLWithPath: "/tmp/x"))
        guard case .unavailable(let reason) = capability else {
            Issue.record("expected unavailable, got \(capability)")
            return
        }
        #expect(reason == "gh not installed")
    }
}
