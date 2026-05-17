import Foundation

/// Computes a `ProjectHealth` snapshot for one Project by probing the primary
/// checkout with cheap git calls. Every failure mode resolves to a degraded
/// status with a human-readable reason instead of throwing, so a single bad
/// repo (missing path, missing git, repo corruption) can never block the rest
/// of the dashboard.
struct ProjectHealthRefresher: HealthProbing, Sendable {
    let gitClient: GitClient
    /// Optional probe for GitHub capability. `nil` skips the probe entirely
    /// so unit tests focused on the git side don't need to stub `gh` and so
    /// the dashboard can decide whether to enable the capability check at
    /// startup.
    let gitHubProbe: (any GitHubCapabilityProbing)?
    let fileManager: FileManager
    let now: @Sendable () -> Date

    init(
        gitClient: GitClient,
        gitHubProbe: (any GitHubCapabilityProbing)? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gitClient = gitClient
        self.gitHubProbe = gitHubProbe
        self.fileManager = fileManager
        self.now = now
    }

    func refresh(_ project: Project) async -> ProjectHealth {
        let primaryURL = URL(fileURLWithPath: project.primaryCheckoutPath)
        let timestamp = now()

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: primaryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            // Skip every git probe: the path is gone, so any call would just
            // produce another "no such directory" failure. The Missing status
            // is what the dashboard uses to surface Relocate / Remove.
            return ProjectHealth(
                status: .missing,
                currentBranch: nil,
                workingTree: nil,
                branchSync: nil,
                worktreeCount: nil,
                gitHub: nil,
                lastRefreshedAt: timestamp
            )
        }

        do {
            // Run the cheap probes in parallel. Worktree discovery and branch
            // sync are best-effort: older git versions or non-standard repos
            // can fail those calls without invalidating branch or status, so
            // we don't let them degrade the whole snapshot.
            async let branchTask = gitClient.currentBranch(at: primaryURL)
            async let dirtyTask = gitClient.isWorkingTreeDirty(at: primaryURL)
            async let syncTask = bestEffortBranchSync(at: primaryURL)
            async let worktreeCountTask = bestEffortWorktreeCount(at: primaryURL)
            async let gitHubTask = bestEffortGitHubCapability(at: primaryURL)

            let branch = try await branchTask
            let isDirty = try await dirtyTask
            let branchSync = await syncTask
            let worktreeCount = await worktreeCountTask
            let gitHub = await gitHubTask

            return ProjectHealth(
                status: .ready,
                currentBranch: branch,
                workingTree: isDirty ? .dirty : .clean,
                branchSync: branchSync,
                worktreeCount: worktreeCount,
                gitHub: gitHub,
                lastRefreshedAt: timestamp
            )
        } catch let CLIError.launchFailed(reason) {
            return degraded("git is unavailable: \(reason)", at: timestamp)
        } catch let CLIError.nonZeroExit(_, stderr, _) {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return degraded(
                message.isEmpty ? "git command failed" : message,
                at: timestamp
            )
        } catch let GitClientError.notInsideRepository(_, underlying) {
            return degraded(
                underlying.isEmpty ? "Not inside a git repository" : underlying,
                at: timestamp
            )
        } catch GitClientError.emptyOutput {
            return degraded("git produced no output", at: timestamp)
        } catch {
            return degraded("git command failed: \(error)", at: timestamp)
        }
    }

    private func bestEffortWorktreeCount(at url: URL) async -> Int {
        let paths = (try? await gitClient.listWorktreePaths(at: url)) ?? []
        // Even when worktree list fails or returns nothing, the primary
        // checkout itself is one tracked checkout, so we never display "0".
        return max(paths.count, 1)
    }

    private func bestEffortGitHubCapability(at url: URL) async -> GitHubCapability? {
        // No probe configured → leave capability nil so the row hides the
        // GitHub badge instead of asserting "unavailable". This keeps tests
        // that focus on git behaviour free of `gh` stubs.
        guard let gitHubProbe else { return nil }
        return await gitHubProbe.probe(at: url)
    }

    private func bestEffortBranchSync(at url: URL) async -> BranchSync? {
        // Returning `nil` here means "unknown" — the row renders that as the
        // dashboard's understandable fallback rather than degrading the whole
        // Project just because porcelain v2 wasn't parseable on this repo.
        try? await gitClient.branchSync(at: url)
    }

    private func degraded(_ reason: String, at timestamp: Date) -> ProjectHealth {
        ProjectHealth(
            status: .degraded(reason: reason),
            currentBranch: nil,
            workingTree: nil,
            branchSync: nil,
            worktreeCount: nil,
            gitHub: nil,
            lastRefreshedAt: timestamp
        )
    }
}
