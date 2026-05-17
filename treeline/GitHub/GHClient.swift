import Foundation

/// Errors raised by `GHClient`. Each case is mapped to a `GitHubCapability`
/// reason by the refresher, so the dashboard never has to grok `gh`'s raw
/// stderr. Cases are intentionally narrow — anything we don't recognise as a
/// known `gh` failure mode falls through to `.unknownFailure(stderr)` rather
/// than being silently treated as "not a GitHub repository".
enum GHClientError: Error, Equatable, Sendable {
    /// `gh` could not be launched — almost always because the binary is not on
    /// disk at the resolved path.
    case ghMissing(reason: String)
    /// `gh` ran but the user is not authenticated for this host.
    case notAuthenticated(stderr: String)
    /// The repository has no GitHub remote, or `gh` cannot map the local
    /// remotes to a GitHub repository.
    case notAGitHubRepository(stderr: String)
    /// `gh` ran but could not reach the GitHub API (offline, DNS, transient).
    case networkFailure(stderr: String)
    /// `gh` failed for a reason we don't classify — surfaced verbatim so the
    /// user can act on it without us guessing at the cause.
    case unknownFailure(stderr: String)
    /// `gh` returned success but the JSON payload was missing or unparseable.
    case malformedOutput(stdout: String)
}

/// Probes optional GitHub capability for a Project by shelling out to `gh`
/// from the primary checkout. Kept deliberately separate from `GitClient`
/// because the two tools have different semantics, identity, and failure
/// modes — but both flow through the same `CLIRunning` chokepoint so test
/// fakes and the real runner stay interchangeable.
struct GHClient: Sendable {
    let runner: any CLIRunning
    let ghExecutableURL: URL

    init(runner: any CLIRunning, ghExecutableURL: URL = GHClient.defaultExecutableURL()) {
        self.runner = runner
        self.ghExecutableURL = ghExecutableURL
    }

    /// Best guess at where `gh` lives on the user's machine. Apps launched
    /// from the Dock don't inherit the user's shell `PATH`, so we probe the
    /// well-known Homebrew locations (Apple Silicon, Intel) before falling
    /// back to a fixed path that will surface as `.ghMissing` on launch.
    static func defaultExecutableURL(fileManager: FileManager = .default) -> URL {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: candidates[0])
    }

    /// Run `gh repo view --json owner,name` from the checkout and parse the
    /// owner/name pair. Any non-zero exit is classified into a typed
    /// `GHClientError` so the refresher can map it to a capability reason.
    func repoIdentity(at checkout: URL) async throws -> GitHubIdentity {
        let invocation = CLIInvocation(
            executableURL: ghExecutableURL,
            arguments: ["repo", "view", "--json", "owner,name"],
            workingDirectory: checkout
        )
        let result: CLIResult
        do {
            result = try await runner.run(invocation)
        } catch let CLIError.launchFailed(reason) {
            throw GHClientError.ghMissing(reason: reason)
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw Self.classify(stderr: stderr)
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GHClientError.malformedOutput(stdout: result.standardOutput)
        }
        guard
            let name = object["name"] as? String, !name.isEmpty,
            let ownerObject = object["owner"] as? [String: Any],
            let login = ownerObject["login"] as? String, !login.isEmpty
        else {
            throw GHClientError.malformedOutput(stdout: result.standardOutput)
        }
        return GitHubIdentity(owner: login, name: name)
    }

    /// Count open pull requests on the checkout's GitHub repository. Uses
    /// `--json number --limit 200` — 200 is plenty for the dashboard summary
    /// and a single API call stays cheap. Counts above 200 are reported as
    /// 200; we can revisit if real dogfooding hits the ceiling.
    func openPullRequestCount(at checkout: URL) async throws -> Int {
        let invocation = CLIInvocation(
            executableURL: ghExecutableURL,
            arguments: ["pr", "list", "--state", "open", "--json", "number", "--limit", "200"],
            workingDirectory: checkout
        )
        let result: CLIResult
        do {
            result = try await runner.run(invocation)
        } catch let CLIError.launchFailed(reason) {
            throw GHClientError.ghMissing(reason: reason)
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            throw Self.classify(stderr: stderr)
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw GHClientError.malformedOutput(stdout: result.standardOutput)
        }
        return array.count
    }

    /// Map `gh`'s stderr to a typed error. We match on substrings rather than
    /// exit codes because `gh` returns the same status (1) for most failures
    /// and only the message disambiguates them.
    static func classify(stderr raw: String) -> GHClientError {
        let stderr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = stderr.lowercased()

        if lower.contains("not authenticated") || lower.contains("authentication required")
            || lower.contains("gh auth login") || lower.contains("http 401") {
            return .notAuthenticated(stderr: stderr)
        }
        if lower.contains("no github remote") || lower.contains("could not determine")
            || lower.contains("not a github") || lower.contains("no such remote")
            || lower.contains("could not resolve to a repository") || lower.contains("http 404") {
            return .notAGitHubRepository(stderr: stderr)
        }
        if lower.contains("dial tcp") || lower.contains("no such host")
            || lower.contains("connection refused") || lower.contains("network is unreachable")
            || lower.contains("timeout") || lower.contains("could not connect") {
            return .networkFailure(stderr: stderr)
        }
        return .unknownFailure(stderr: stderr)
    }
}

extension GHClientError {
    /// Human-readable warning text shown on the dashboard when the capability
    /// is unavailable. Kept here so the wording stays close to the typed
    /// cause and the refresher only has to do one mapping step.
    var capabilityReason: String {
        switch self {
        case .ghMissing:
            return "gh not installed"
        case .notAuthenticated:
            return "gh not authenticated"
        case .notAGitHubRepository:
            return "No GitHub remote"
        case .networkFailure:
            return "GitHub unreachable"
        case .unknownFailure(let stderr):
            return stderr.isEmpty ? "gh command failed" : stderr
        case .malformedOutput:
            return "gh produced unexpected output"
        }
    }
}

/// Probing surface for the dashboard's GitHub capability check. The concrete
/// `GHClient` conforms via the extension below; tests inject a fake that
/// returns canned capability states without shelling out.
protocol GitHubCapabilityProbing: Sendable {
    func probe(at checkout: URL) async -> GitHubCapability
}

extension GHClient: GitHubCapabilityProbing {
    /// Run the two probes in order: identity first (cheap, decides whether
    /// GitHub is on the table at all), then PR count. A PR-count failure
    /// after a successful identity probe keeps the capability `.capable` with
    /// a `nil` count instead of erasing the GitHub badge entirely.
    func probe(at checkout: URL) async -> GitHubCapability {
        let identity: GitHubIdentity
        do {
            identity = try await repoIdentity(at: checkout)
        } catch let error as GHClientError {
            return .unavailable(reason: error.capabilityReason)
        } catch {
            return .unavailable(reason: String(describing: error))
        }

        let count: Int?
        do {
            count = try await openPullRequestCount(at: checkout)
        } catch {
            count = nil
        }
        return .capable(identity: identity, openPullRequestCount: count)
    }
}
